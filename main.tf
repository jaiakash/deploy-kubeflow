# Root orchestration — calls modules in dependency order.

# ============================================================
# Layer 0: OKE Cluster (VCN + networking + OKE + node pool)
# ============================================================
# Creates the OCI infrastructure. All other modules depend on
# this cluster existing and the kubeconfig being generated.

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
# Phase 1: Kubeflow Platform (via Kustomize wrapper)
# ============================================================
# Installed first because Milvus, RBAC, and the API server all depend
# on Istio, cert-manager, and the kubeflow namespace being present.

module "kubeflow_platform" {
  source = "./modules/kubeflow-platform"

  kf_version      = var.kf_version
  kf_components   = var.kf_components
  kubeconfig_path = var.kubeconfig_path

  depends_on = [module.oke_cluster]
}

# ============================================================
# Phase 2: Milvus (Helm — standalone, no persistence for dev)
# ============================================================

module "milvus" {
  source = "./modules/milvus"

  namespace      = var.milvus_namespace
  release_name   = var.milvus_release_name
  chart_version  = var.milvus_chart_version
  istio_enabled  = var.istio_enabled

  depends_on = [module.kubeflow_platform]
}

# ============================================================
# Phase 3: RBAC (allow KFP service account → Milvus)
# ============================================================

module "rbac" {
  source = "./modules/rbac"

  namespace = var.milvus_namespace

  depends_on = [module.milvus]
}

# ============================================================
# Phase 4: MCP Server (FastMCP tool server for kagent)
# ============================================================

module "mcp_server" {
  source = "./modules/mcp-server"

  namespace       = var.milvus_namespace
  image           = var.mcp_image
  replicas        = var.mcp_replicas
  milvus_host     = module.milvus.milvus_host
  milvus_port     = module.milvus.milvus_port
  milvus_password = var.milvus_password

  depends_on = [module.milvus, module.rbac]
}

# ============================================================
# Phase 5: KServe LLM (optional — GPU required)
# ============================================================
# count = 0 by default; set var.deploy_kserve = true to activate.

module "kserve_llm" {
  source = "./modules/kserve-llm"
  count  = var.deploy_kserve ? 1 : 0

  namespace         = var.milvus_namespace
  model_id          = var.kserve_model_id
  huggingface_token = var.huggingface_token

  depends_on = [module.kubeflow_platform]
}

# ============================================================
# Phase 6b: kagent (agent orchestration + UI)
# ============================================================

module "kagent" {
  source = "./modules/kagent"

  namespace      = var.milvus_namespace
  groq_api_key   = var.groq_api_key
  llm_model      = var.llm_model
  llm_base_url   = var.llm_base_url
  mcp_server_url = module.mcp_server.mcp_endpoint

  depends_on = [module.mcp_server]
}
