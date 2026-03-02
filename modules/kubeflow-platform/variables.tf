variable "kf_version" {
  description = "Kubeflow manifests Git branch or tag"
  type        = string
}

variable "kf_components" {
  description = "List of kustomize component paths to install"
  type        = list(string)
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig for the OKE cluster"
  type        = string
}
