#!/usr/bin/env bash
# install-kubeflow.sh — Install Kubeflow components via kustomize.
# Called by the kubeflow-platform Terraform module as a local-exec provisioner.
#
# Required env vars:
#   KUBECONFIG    — path to kubeconfig for the target cluster
#   KF_VERSION    — kubeflow/manifests Git branch or tag (e.g. "master", "v1.9.0")
#   KF_COMPONENTS — comma-separated list of kustomize paths relative to manifests root
set -euo pipefail

MANIFESTS_DIR="/tmp/kubeflow-manifests"
MANIFESTS_REPO="https://github.com/kubeflow/manifests.git"
MAX_RETRIES=8
RETRY_WAIT=30

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---- Validate prereqs ----
for cmd in kubectl kustomize git; do
  if ! command -v "$cmd" &>/dev/null; then
    log "❌ Required command not found: $cmd — install it before running Terraform"
    exit 1
  fi
done

log "kubectl:   $(kubectl version --client -o json 2>/dev/null | python3 -c "import sys,json; v=json.load(sys.stdin)['clientVersion']; print(v['gitVersion'])" 2>/dev/null || echo 'unknown')"
log "kustomize: $(kustomize version 2>/dev/null | head -1 || echo 'unknown')"
log "Target cluster: $(kubectl --kubeconfig="$KUBECONFIG" cluster-info 2>&1 | head -1)"

# ---- Clone or update manifests ----
if [ -d "$MANIFESTS_DIR/.git" ]; then
  log "Manifests already cloned — fetching latest and checking out $KF_VERSION..."
  git -C "$MANIFESTS_DIR" fetch --depth=1 --all --quiet
  git -C "$MANIFESTS_DIR" checkout "$KF_VERSION" --quiet 2>/dev/null || \
    git -C "$MANIFESTS_DIR" checkout -b "$KF_VERSION" "origin/$KF_VERSION" --quiet
else
  log "Cloning kubeflow/manifests at $KF_VERSION..."
  git clone --depth=1 --branch "$KF_VERSION" "$MANIFESTS_REPO" "$MANIFESTS_DIR"
fi

log "Manifests ready at $MANIFESTS_DIR ($(git -C "$MANIFESTS_DIR" rev-parse --short HEAD))"

# ---- Apply each component with retry ----
# Retry is necessary because CRDs (e.g. cert-manager, Istio) take time to
# become established after their first apply. Subsequent components that use
# those CRDs will fail on the first attempt and succeed on retry.
# --server-side avoids the "metadata.annotations size exceeds 262144 bytes"
# error that some large Kubeflow manifests trigger with client-side apply.
apply_component() {
  local component="$1"
  local full_path="$MANIFESTS_DIR/$component"

  if [ ! -d "$full_path" ]; then
    log "❌ Component path not found: $full_path"
    return 1
  fi

  for attempt in $(seq 1 "$MAX_RETRIES"); do
    log "Applying [$attempt/$MAX_RETRIES] $component..."
    local output
    if output=$(
      {
        kustomize build "$full_path" \
        | sed -E '
            s|image: kserve/|image: docker.io/kserve/|g;
            s|image: mysql:|image: docker.io/mysql:|g;
            s|image: chrislusf/|image: docker.io/chrislusf/|g;
            /mysql-native-password=ON/d
          ' \
        | kubectl apply --server-side --force-conflicts \
            --kubeconfig="$KUBECONFIG" -f -
      } 2>&1
    ); then
      echo "$output"
      log "✅ $component"
      return 0
    fi
    echo "$output"
    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
      # If a webhook is failing, wait for its deployment to become ready
      if echo "$output" | grep -q "failed calling webhook"; then
        log "⏳ Webhook not ready — waiting for deployments in kubeflow namespace (up to 90s)..."
        kubectl wait --for=condition=Available deployment --all \
          -n kubeflow --timeout=90s --kubeconfig="$KUBECONFIG" 2>/dev/null || true
      else
        log "⏳ Retrying in ${RETRY_WAIT}s (CRDs may still be propagating)..."
        sleep "$RETRY_WAIT"
      fi
    fi
  done

  log "❌ Failed to apply $component after $MAX_RETRIES attempts"
  return 1
}

# ---- Fix short-name images for CRI-O (OKE uses CRI-O with strict enforcement) ----
# OCI OKE nodes reject images without an explicit registry prefix.
# KServe manifests use short names like "kserve/kserve-controller:v0.16.0"
# which CRI-O can't resolve. This patches them to fully-qualified names.
fix_short_name_images() {
  log "Patching short-name container images for CRI-O compatibility..."

  # Collect all deployments in kubeflow namespace and fix unqualified images
  local deployments
  deployments=$(kubectl get deployments -n kubeflow -o jsonpath='{.items[*].metadata.name}' \
    --kubeconfig="$KUBECONFIG" 2>/dev/null || true)

  for deploy in $deployments; do
    # Get all container images for this deployment
    local images
    images=$(kubectl get deployment "$deploy" -n kubeflow \
      -o jsonpath='{.spec.template.spec.containers[*].image}' \
      --kubeconfig="$KUBECONFIG" 2>/dev/null || true)

    for image in $images; do
      # Skip if already fully qualified (contains a dot before the first slash = has registry)
      if echo "$image" | grep -qE '^[^/]+\.[^/]+/'; then
        continue
      fi
      # Skip single-word images (e.g. "busybox") — unlikely in KF but be safe
      if ! echo "$image" | grep -q '/'; then
        continue
      fi
      # Image is like "kserve/kserve-controller:v0.16.0" — prefix with docker.io
      local qualified="docker.io/$image"
      local container_name
      # Find which container uses this image
      container_name=$(kubectl get deployment "$deploy" -n kubeflow \
        -o jsonpath="{.spec.template.spec.containers[?(@.image=='$image')].name}" \
        --kubeconfig="$KUBECONFIG" 2>/dev/null || true)
      if [ -n "$container_name" ]; then
        log "  Fixing $deploy/$container_name: $image → $qualified"
        kubectl set image "deployment/$deploy" "$container_name=$qualified" \
          -n kubeflow --kubeconfig="$KUBECONFIG" 2>/dev/null || true
      fi
    done
  done

  log "Image patching complete."
}

# ---- Wait for KServe webhook after patching ----
wait_for_kserve_webhook() {
  log "Waiting for KServe webhook to become ready (up to 3m)..."
  kubectl wait --for=condition=Available deployment/kserve-controller-manager \
    -n kubeflow --timeout=180s --kubeconfig="$KUBECONFIG" 2>/dev/null || \
    log "⚠️  KServe controller not ready yet — subsequent applies will retry"

  # Give the webhook endpoint a moment to register
  sleep 5
}

# ---- Ensure MySQL PVC exists before Pipelines install ----
# Kubeflow Pipelines expects a PVC named mysql-pv-claim but the manifests
# don't always create it. On OKE we use the oci-bv (block volume) StorageClass.
ensure_mysql_pvc() {
  if kubectl get pvc mysql-pv-claim -n kubeflow --kubeconfig="$KUBECONFIG" >/dev/null 2>&1; then
    log "mysql-pv-claim PVC already exists — skipping"
    return 0
  fi

  log "Creating mysql-pv-claim PVC for Kubeflow Pipelines..."
  cat <<EOF | kubectl apply --kubeconfig="$KUBECONFIG" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pv-claim
  namespace: kubeflow
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: oci-bv
  resources:
    requests:
      storage: 20Gi
EOF
}

IFS=',' read -ra COMPONENTS <<< "$KF_COMPONENTS"
log "Installing ${#COMPONENTS[@]} Kubeflow components..."

for component in "${COMPONENTS[@]}"; do
  # Ensure MySQL PVC exists before installing Pipelines
  if echo "$component" | grep -q "pipeline"; then
    ensure_mysql_pvc
  fi

  apply_component "$component"

  # After KServe base is applied, fix images and wait for webhook
  if echo "$component" | grep -q "kserve/kserve$"; then
    fix_short_name_images
    wait_for_kserve_webhook
  fi
done

# ---- Wait for core components ----
log "Waiting for cert-manager deployments to be available (timeout 5m)..."
kubectl wait --for=condition=Available deployment --all \
  -n cert-manager --timeout=300s --kubeconfig="$KUBECONFIG" 2>/dev/null || \
  log "⚠️  cert-manager wait timed out — pods may still be starting"

log "Waiting for Istio control plane (timeout 5m)..."
kubectl wait --for=condition=Available deployment --all \
  -n istio-system --timeout=300s --kubeconfig="$KUBECONFIG" 2>/dev/null || \
  log "⚠️  istio-system wait timed out — pods may still be starting"

log "Waiting for kubeflow namespace deployments (timeout 5m)..."
kubectl wait --for=condition=Available deployment --all \
  -n kubeflow --timeout=300s --kubeconfig="$KUBECONFIG" 2>/dev/null || \
  log "⚠️  kubeflow namespace wait timed out — pods may still be starting"

log "✅ Kubeflow installation complete — run 'kubectl get pods -A' to verify"
