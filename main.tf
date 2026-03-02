# Root orchestration — calls modules in dependency order.
# Akash's OKE cluster module is assumed to already exist and have
# written a kubeconfig to var.kubeconfig_path before this runs.

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
}

# ============================================================
# Phase 2: Milvus (Helm — standalone, no persistence for dev)
# ============================================================

module "milvus" {
  source = "./modules/milvus"

  namespace     = var.milvus_namespace
  release_name  = var.milvus_release_name
  chart_version = var.milvus_chart_version

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
# Phase 4: API Server (FastAPI docs-agent)
# ============================================================

module "api_server" {
  source = "./modules/api-server"

  namespace  = var.milvus_namespace
  image      = var.api_image
  replicas   = var.api_replicas
  milvus_host = module.milvus.milvus_host
  milvus_port = module.milvus.milvus_port

  # LLM endpoint — switches between external API and KServe automatically
  llm_endpoint = var.deploy_kserve ? module.kserve_llm[0].kserve_endpoint : var.external_llm_endpoint
  llm_model    = var.deploy_kserve ? var.kserve_model_id : var.external_llm_model
  llm_api_key  = var.external_llm_api_key

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
