variable "namespace" {
  description = "Namespace to install kagent and deploy the Agent CRDs into"
  type        = string
}

variable "groq_api_key" {
  description = "Groq API key — referenced by the kagent ModelConfig"
  type        = string
  sensitive   = true
}

variable "llm_model" {
  description = "Groq model name to use for the agent"
  type        = string
  default     = "llama-3.1-8b-instant"
}

variable "llm_base_url" {
  description = "OpenAI-compatible base URL for the LLM provider"
  type        = string
  default     = "https://api.groq.com/openai/v1"
}

variable "mcp_server_url" {
  description = "In-cluster URL of the MCP server (from mcp-server module output)"
  type        = string
}
