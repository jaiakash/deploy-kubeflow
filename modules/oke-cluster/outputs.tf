output "cluster_id" {
  description = "OKE cluster OCID"
  value       = oci_containerengine_cluster.main.id
}

output "cluster_endpoint" {
  description = "Public IP of the OKE API server endpoint"
  value       = oci_containerengine_cluster.main.endpoints[0].public_endpoint
}

output "node_pool_id" {
  description = "OKE node pool OCID"
  value       = oci_containerengine_node_pool.main.id
}

output "kubeconfig_command" {
  description = "OCI CLI command to generate kubeconfig for this cluster"
  value       = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.main.id} --region ${var.region} --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT"
}
