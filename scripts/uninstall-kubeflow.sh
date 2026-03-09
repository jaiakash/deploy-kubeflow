#!/usr/bin/env bash
# uninstall-kubeflow.sh — Remove Kubeflow components in reverse install order.
# Called by the kubeflow-platform Terraform module destroy provisioner.
#
# Required env vars (read from self.triggers in Terraform):
#   KUBECONFIG    — path to kubeconfig for the target cluster
#   KF_VERSION    — used to locate the manifests directory
#   KF_COMPONENTS — comma-separated component list (same as install, reversed here)
set -euo pipefail

MANIFESTS_DIR="/tmp/kubeflow-manifests"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

if [ ! -d "$MANIFESTS_DIR" ]; then
  log "⚠️  Manifests directory not found at $MANIFESTS_DIR — nothing to uninstall"
  exit 0
fi

IFS=',' read -ra COMPONENTS <<< "$KF_COMPONENTS"

# Reverse the array — uninstall order is opposite of install order
REVERSED=()
for (( i=${#COMPONENTS[@]}-1; i>=0; i-- )); do
  REVERSED+=("${COMPONENTS[$i]}")
done

log "Uninstalling ${#REVERSED[@]} Kubeflow components (reverse order)..."

for component in "${REVERSED[@]}"; do
  full_path="$MANIFESTS_DIR/$component"
  if [ -d "$full_path" ]; then
    log "Deleting $component..."
    kustomize build "$full_path" | \
      kubectl delete --kubeconfig="$KUBECONFIG" --ignore-not-found=true -f - 2>&1 || \
      log "⚠️  $component delete encountered errors (may already be gone)"
  else
    log "⚠️  Skipping $component — path not found: $full_path"
  fi
done

log "✅ Kubeflow uninstallation complete"
