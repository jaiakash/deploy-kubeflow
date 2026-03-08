# Root orchestration — calls modules in dependency order.

# ============================================================
# Layer 0: OKE Cluster (VCN + networking + OKE + node pool)
# ============================================================
# Creates the OCI infrastructure: VCN, subnets, security lists,
# gateways, OKE cluster, and x86 node pool.

module "oke_cluster" {
  source = "./modules/oke-cluster"

  compartment_id      = var.compartment_id
  region              = var.region
  cluster_name        = var.cluster_name
  k8s_version         = var.k8s_version
  node_count          = var.node_count
  node_ocpus          = var.node_ocpus
  node_memory_gb      = var.node_memory_gb
  node_boot_volume_gb = var.node_boot_volume_gb
}

# ============================================================
# Layer 1: Kubeflow Platform (via Kustomize wrapper)
# ============================================================
# Installs Kubeflow components via kustomize build | kubectl apply.
# Includes: cert-manager, Istio, Dex, Knative, KServe, Pipelines,
# Central Dashboard, and Profiles.

module "kubeflow_platform" {
  source = "./modules/kubeflow-platform"

  kf_version      = var.kf_version
  kf_components   = var.kf_components
  kubeconfig_path = var.kubeconfig_path

  depends_on = [module.oke_cluster]
}
