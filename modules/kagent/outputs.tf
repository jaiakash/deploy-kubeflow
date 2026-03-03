output "agent_name" {
  description = "Name of the deployed kagent Agent resource"
  value       = kubernetes_manifest.agent.manifest.metadata.name
}

output "kagent_ui_command" {
  description = "Port-forward command to access the kagent UI"
  value       = "kubectl -n ${var.namespace} port-forward service/kagent-ui 8080:8080"
}
