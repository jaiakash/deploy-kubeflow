# ============================================================
# OCI Authentication
# ============================================================

variable "compartment_id" {
  description = "OCI compartment OCID to deploy all resources into"
  type        = string
}

variable "tenancy_ocid" {
  description = "OCID of your OCI tenancy"
  type        = string
}

variable "user_ocid" {
  description = "OCID of the OCI user running Terraform"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the API signing key"
  type        = string
}

variable "private_key_path" {
  description = "Local path to the OCI API private key (.pem)"
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  description = "OCI region (e.g. us-ashburn-1)"
  type        = string
  default     = "us-ashburn-1"
}

# ============================================================
# OKE Cluster
# ============================================================

variable "cluster_name" {
  description = "Display name for the OKE cluster and VCN resources"
  type        = string
  default     = "kubeflow-cluster"
}

variable "k8s_version" {
  description = "Kubernetes version for the OKE cluster (e.g. v1.31.1)"
  type        = string
  default     = "v1.34.2"
}

variable "node_count" {
  description = "Number of x86 worker nodes"
  type        = number
  default     = 2
}

variable "node_ocpus" {
  description = "OCPUs per node (E5.Flex shape)"
  type        = number
  default     = 2
}

variable "node_memory_gb" {
  description = "Memory per node in GB"
  type        = number
  default     = 12
}

variable "node_boot_volume_gb" {
  description = "Boot volume size per node in GB"
  type        = number
  default     = 50
}

# ============================================================
# Cluster Access
# ============================================================

variable "kubeconfig_path" {
  description = "Path to the kubeconfig for the OKE cluster"
  type        = string
  default     = "~/.kube/config"
}

# ============================================================
# Kubeflow Platform
# ============================================================

variable "kf_version" {
  description = "Kubeflow manifests Git branch or tag to install"
  type        = string
  default     = "master"
}

variable "kf_components" {
  description = "List of Kubeflow component paths (relative to manifests repo) to install via kustomize"
  type        = list(string)
  default = [
    # Order matters — CRDs and namespaces first, then components that depend on them.
    "common/kubeflow-namespace/base",
    "common/kubeflow-roles/base",
    "common/cert-manager/base",
    "common/istio/istio-crds/base",
    "common/istio/istio-namespace/base",
    "common/istio/istio-install/overlays/oauth2-proxy",
    "common/oauth2-proxy/overlays/m2m-dex-and-kind",
    "common/dex/overlays/oauth2-proxy",
    "common/knative/knative-serving/overlays/gateways",
    "common/istio/kubeflow-istio-resources/base",
    "applications/kserve/kserve",
    "applications/kserve/models-web-app/overlays/kubeflow",
    "applications/pipeline/upstream/env/cert-manager/platform-agnostic-multi-user",
    "applications/centraldashboard/overlays/oauth2-proxy",
    "applications/profiles/upstream/overlays/kubeflow",
  ]
}
