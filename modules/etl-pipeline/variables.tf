# ============================================================
# ETL Pipeline — Input Variables
# ============================================================

variable "namespace" {
  description = "Kubernetes namespace where the ETL job runs (same as Milvus)"
  type        = string
}

variable "image" {
  description = "Docker image for the ETL pipeline (must include sentence-transformers, pymilvus, langchain, etc.)"
  type        = string
}

# ---- Milvus connection ----

variable "milvus_host" {
  description = "In-cluster Milvus hostname"
  type        = string
}

variable "milvus_port" {
  description = "Milvus gRPC port"
  type        = number
  default     = 19530
}

variable "milvus_password" {
  description = "Milvus root password"
  type        = string
  sensitive   = true
  default     = "Milvus"
}

# ---- GitHub source ----

variable "github_token" {
  description = "GitHub personal access token for API rate limits (optional but recommended)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_repo" {
  description = "GitHub repo to crawl for docs (owner/repo format)"
  type        = string
  default     = "kubeflow/website"
}

variable "github_docs_path" {
  description = "Path within the repo to crawl for documentation"
  type        = string
  default     = "content/en/docs"
}

# ---- Indexing parameters ----

variable "collection_name" {
  description = "Milvus collection name for the indexed documents"
  type        = string
  default     = "kubeflow_docs_docs_rag"
}

variable "embedding_model" {
  description = "Sentence-transformers model for generating embeddings (768-dim)"
  type        = string
  default     = "sentence-transformers/all-mpnet-base-v2"
}

variable "chunk_size" {
  description = "Character count per document chunk"
  type        = number
  default     = 1000
}

variable "chunk_overlap" {
  description = "Overlap between consecutive chunks in characters"
  type        = number
  default     = 100
}

# ---- Job behaviour ----

variable "backoff_limit" {
  description = "Number of retries before marking the Job as failed"
  type        = number
  default     = 3
}

variable "ttl_seconds_after_finished" {
  description = "Seconds to keep the completed/failed Job before GC (0 = delete immediately)"
  type        = number
  default     = 3600
}

# ---- Resource limits ----

variable "cpu_request" {
  description = "CPU request for the ETL container"
  type        = string
  default     = "1"
}

variable "cpu_limit" {
  description = "CPU limit for the ETL container"
  type        = string
  default     = "2"
}

variable "memory_request" {
  description = "Memory request for the ETL container (sentence-transformers needs ~2Gi)"
  type        = string
  default     = "2Gi"
}

variable "memory_limit" {
  description = "Memory limit for the ETL container"
  type        = string
  default     = "4Gi"
}
