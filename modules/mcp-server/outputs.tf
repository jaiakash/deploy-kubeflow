output "mcp_endpoint" {
  description = "In-cluster MCP endpoint URL (used by kagent RemoteMCPServer)"
  value       = "http://${kubernetes_service_v1.mcp_server.metadata[0].name}.${kubernetes_service_v1.mcp_server.metadata[0].namespace}.svc.cluster.local:8000/mcp"
}
