output "api_endpoint" {
  description = "In-cluster URL for the docs-agent API server"
  value       = "http://${kubernetes_service_v1.api_server.metadata[0].name}.${kubernetes_service_v1.api_server.metadata[0].namespace}.svc.cluster.local:8000"
}
