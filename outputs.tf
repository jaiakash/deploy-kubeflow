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

output "kubeflow_dashboard_command" {
  description = "Port-forward command to access the Kubeflow dashboard"
  value       = "kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80"
}
