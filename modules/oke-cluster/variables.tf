variable "compartment_id" {
  description = "OCI compartment OCID to create all resources in"
  type        = string
}

variable "region" {
  description = "OCI region (e.g. us-ashburn-1)"
  type        = string
}

variable "cluster_name" {
  description = "Display name for the OKE cluster and associated resources"
  type        = string
  default     = "kubeflow-cluster"
}

variable "k8s_version" {
  description = "Kubernetes version for the OKE cluster and node pool (e.g. v1.31.1)"
  type        = string
  default     = "v1.34.2"
}

variable "node_count" {
  description = "Number of worker nodes (2 recommended for HA)"
  type        = number
  default     = 2
}

variable "node_ocpus" {
  description = "OCPUs per node (E5.Flex shape)"
  type        = number
  default     = 2
}

variable "node_memory_gb" {
  description = "Memory (GB) per node (E5.Flex shape)"
  type        = number
  default     = 12
}

variable "node_boot_volume_gb" {
  description = "Boot volume size (GB) per node"
  type        = number
  default     = 50
}

variable "vcn_cidr" {
  description = "CIDR block for the VCN"
  type        = string
  default     = "10.0.0.0/16"
}
