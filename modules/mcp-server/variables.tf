variable "namespace" {
  description = "Namespace to deploy the MCP server into"
  type        = string
}

variable "image" {
  description = <<-EOT
    Docker image for the MCP server (kagent-feast-mcp/mcp-server/).
    Santosh is building and publishing this image.
    Source: https://github.com/kubeflow/docs-agent/tree/main/kagent-feast-mcp/mcp-server
  EOT
  type        = string
}

variable "replicas" {
  description = "Number of MCP server replicas"
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

variable "milvus_password" {
  description = "Milvus root password (default Milvus install uses 'Milvus')"
  type        = string
  sensitive   = true
  default     = "Milvus"
}
