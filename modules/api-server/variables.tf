variable "namespace" {
  description = "Namespace to deploy the docs-agent API server into"
  type        = string
}

variable "image" {
  description = "Docker image for the docs-agent API server"
  type        = string
}

variable "replicas" {
  description = "Number of API server replicas"
  type        = number
  default     = 1
}

variable "milvus_host" {
  description = "In-cluster hostname of the Milvus service"
  type        = string
}

variable "milvus_port" {
  description = "Milvus gRPC port"
  type        = number
}

variable "llm_endpoint" {
  description = "OpenAI-compatible LLM chat completions endpoint"
  type        = string
}

variable "llm_model" {
  description = "Model name to pass to the LLM endpoint"
  type        = string
}

variable "llm_api_key" {
  description = "API key for the LLM endpoint (empty when using KServe)"
  type        = string
  sensitive   = true
  default     = ""
}
