output "api_endpoint" {
  description = "External URL for the docs-agent API server"
  # Placeholder — real value comes from a LoadBalancer/Ingress in Phase 4.
  value = "http://docs-agent-api.${var.namespace}.svc.cluster.local:8000"
}
