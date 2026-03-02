variable "namespace" {
  description = "Namespace where KServe resources will be created"
  type        = string
}

variable "model_id" {
  description = "HuggingFace model ID to serve (e.g. RedHatAI/Llama-3.1-8B-Instruct)"
  type        = string
}

variable "huggingface_token" {
  description = "HuggingFace token for downloading gated models"
  type        = string
  sensitive   = true
}
