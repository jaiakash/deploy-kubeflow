output "role_name" {
  description = "Name of the milvus-access Role"
  value       = kubernetes_role_v1.milvus_access.metadata[0].name
}

output "role_binding_name" {
  description = "Name of the kfp-to-milvus-editor RoleBinding"
  value       = kubernetes_role_binding_v1.kfp_to_milvus_editor.metadata[0].name
}
