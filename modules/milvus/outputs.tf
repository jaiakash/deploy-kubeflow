output "milvus_host" {
  description = "In-cluster DNS hostname for Milvus"
  # Format: <release-name>-milvus.<namespace>.svc.cluster.local
  value = "${var.release_name}-milvus.${var.namespace}.svc.cluster.local"
}

output "milvus_port" {
  description = "Milvus gRPC port"
  value       = 19530
}
