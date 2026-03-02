variable "namespace" {
  description = "Kubernetes namespace for Milvus"
  type        = string
}

variable "release_name" {
  description = "Helm release name for Milvus"
  type        = string
}

variable "chart_version" {
  description = "Milvus Helm chart version"
  type        = string
}
