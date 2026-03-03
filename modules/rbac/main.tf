# Role: read-only access to Milvus services inside docs-agent namespace.
# Scoped to services + endpoints only — minimal privilege principle.
# KFP pipeline steps need this to resolve the Milvus service address
# at runtime without hardcoding an IP that changes on pod restart.
resource "kubernetes_role_v1" "milvus_access" {
  metadata {
    name      = "milvus-access"
    namespace = var.namespace
  }

  rule {
    api_groups = [""]
    resources  = ["services", "endpoints"]
    verbs      = ["get", "list", "watch"]
  }
}

# RoleBinding: grants the role to KFP's default-editor service account.
# default-editor is the service account Kubeflow Pipelines assigns to
# every pipeline step pod that runs in the kubeflow namespace.
# Cross-namespace binding (subject is in kubeflow, role is in docs-agent)
# is valid — RoleBindings can reference subjects from any namespace.
resource "kubernetes_role_binding_v1" "kfp_to_milvus_editor" {
  metadata {
    name      = "kfp-to-milvus-editor"
    namespace = var.namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.milvus_access.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "default-editor"
    namespace = "kubeflow"
  }
}
