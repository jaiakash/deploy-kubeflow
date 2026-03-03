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
MAX_RETRIES=5
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
  git -C "$MANIFESTS_DIR" fetch --all --quiet
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
    if kustomize build "$full_path" | kubectl apply --server-side --kubeconfig="$KUBECONFIG" -f -; then
      log "✅ $component"
      return 0
    fi
    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
      log "⏳ Retrying in ${RETRY_WAIT}s (CRDs may still be propagating)..."
      sleep "$RETRY_WAIT"
    fi
  done

  log "❌ Failed to apply $component after $MAX_RETRIES attempts"
  return 1
}

IFS=',' read -ra COMPONENTS <<< "$KF_COMPONENTS"
log "Installing ${#COMPONENTS[@]} Kubeflow components..."

for component in "${COMPONENTS[@]}"; do
  apply_component "$component"
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
