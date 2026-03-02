output "kserve_endpoint" {
  description = "KServe InferenceService chat completions endpoint"
  # Cluster-local URL following KServe naming convention
  value = "http://llama.${var.namespace}.svc.cluster.local/openai/v1/chat/completions"
}
