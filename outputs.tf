output "api_endpoint" {
  description = "External URL for the docs-agent API server"
  value       = module.api_server.api_endpoint
}

output "milvus_host" {
  description = "In-cluster DNS hostname for Milvus"
  value       = module.milvus.milvus_host
}

output "milvus_port" {
  description = "Milvus gRPC port"
  value       = module.milvus.milvus_port
}

output "kserve_endpoint" {
  description = "KServe inference endpoint (empty when deploy_kserve = false)"
  value       = var.deploy_kserve ? module.kserve_llm[0].kserve_endpoint : "N/A — using external LLM"
}
