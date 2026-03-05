output "cluster_id" {
  description = "OKE cluster OCID"
  value       = module.oke_cluster.cluster_id
}

output "cluster_endpoint" {
  description = "Public IP of the OKE API server"
  value       = module.oke_cluster.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Run this after apply to generate your kubeconfig"
  value       = module.oke_cluster.kubeconfig_command
}

output "mcp_endpoint" {
  description = "In-cluster MCP server URL (used by kagent RemoteMCPServer)"
  value       = module.mcp_server.mcp_endpoint
}

output "kagent_ui_command" {
  description = "Port-forward command to access the kagent UI"
  value       = module.kagent.kagent_ui_command
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
  description = "KServe inference endpoint (N/A when deploy_kserve = false)"
  value       = var.deploy_kserve ? module.kserve_llm[0].kserve_endpoint : "N/A — using Groq external LLM"
}

output "etl_job_name" {
  description = "ETL pipeline Job name (N/A when run_etl_pipeline = false)"
  value       = var.run_etl_pipeline ? module.etl_pipeline[0].job_name : "N/A"
}
