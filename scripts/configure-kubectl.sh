#!/usr/bin/env bash
# configure-kubectl.sh — Generate kubeconfig for an OCI OKE cluster.
# Run this once after Akash's OKE cluster module creates the cluster,
# before running 'terraform apply' for the docs-agent stack.
#
# Usage:
#   CLUSTER_ID=ocid1.cluster.oc1... \
#   REGION=us-ashburn-1 \
#   KUBECONFIG_PATH=~/.kube/config \
#   ./scripts/configure-kubectl.sh
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

: "${CLUSTER_ID:?Required: CLUSTER_ID (OKE cluster OCID)}"
: "${REGION:?Required: REGION (e.g. us-ashburn-1)}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"

if ! command -v oci &>/dev/null; then
  log "❌ OCI CLI not found — install it first: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"
  exit 1
fi

# Ensure the directory exists
mkdir -p "$(dirname "$KUBECONFIG_PATH")"

log "Generating kubeconfig for cluster $CLUSTER_ID in $REGION..."
oci ce cluster create-kubeconfig \
  --cluster-id "$CLUSTER_ID" \
  --file "$KUBECONFIG_PATH" \
  --region "$REGION" \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT

log "Verifying cluster connection..."
kubectl --kubeconfig="$KUBECONFIG_PATH" cluster-info
kubectl --kubeconfig="$KUBECONFIG_PATH" get nodes

log "✅ kubeconfig written to $KUBECONFIG_PATH"
log "   Set KUBECONFIG=$KUBECONFIG_PATH or pass -var=\"kubeconfig_path=$KUBECONFIG_PATH\" to terraform"
