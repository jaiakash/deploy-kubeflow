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

variable "istio_enabled" {
  description = "Set to true when Istio is installed (full OCI cluster). Deploys AuthorizationPolicies to allow traffic to Milvus, etcd, and MinIO pods."
  type        = bool
  default     = true
}
