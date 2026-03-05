output "job_name" {
  description = "Name of the ETL Kubernetes Job"
  value       = kubernetes_job_v1.etl_pipeline.metadata[0].name
}

output "collection_name" {
  description = "Milvus collection populated by the ETL pipeline"
  value       = var.collection_name
}
