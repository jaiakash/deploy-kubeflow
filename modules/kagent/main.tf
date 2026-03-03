# ── Helm: kagent CRDs ────────────────────────────────────────────────────────
# Must be installed before the controller so CRD types are registered.
resource "helm_release" "kagent_crds" {
  name      = "kagent-crds"
  chart     = "oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds"
  namespace = var.namespace

  # OCI charts don't use a repository block — chart URI is the full reference.
  wait    = true
  timeout = 300
}

# ── Helm: kagent controller ───────────────────────────────────────────────────
# Installs the kagent operator and UI. All built-in platform agents are
# disabled — we only need the controller for our custom Agent CRD.
resource "helm_release" "kagent" {
  name      = "kagent"
  chart     = "oci://ghcr.io/kagent-dev/kagent/helm/kagent"
  namespace = var.namespace

  wait    = true
  timeout = 300

  values = [yamlencode({
    agents = {
      argo-rollouts-agent  = { enabled = false }
      cilium-debug-agent   = { enabled = false }
      cilium-manager-agent = { enabled = false }
      cilium-policy-agent  = { enabled = false }
      helm-agent           = { enabled = false }
      istio-agent          = { enabled = false }
      k8s-agent            = { enabled = false }
      kgateway-agent       = { enabled = false }
      observability-agent  = { enabled = false }
      promql-agent         = { enabled = false }
    }
    tools = {
      grafana-mcp = { enabled = false }
      querydoc    = { enabled = false }
    }
  })]

  depends_on = [helm_release.kagent_crds]
}

# ── Groq API key secret ───────────────────────────────────────────────────────
# Referenced by the ModelConfig below via apiKeySecret + apiKeySecretKey.
resource "kubernetes_secret_v1" "groq" {
  metadata {
    name      = "kagent-groq"
    namespace = var.namespace
  }

  data = {
    GROQ_API_KEY = var.groq_api_key
  }
}

# ── ModelConfig — LLM provider ────────────────────────────────────────────────
# Groq is OpenAI-compatible; provider = "OpenAI" with a custom baseUrl.
resource "kubernetes_manifest" "model_config" {
  manifest = {
    apiVersion = "kagent.dev/v1alpha2"
    kind       = "ModelConfig"
    metadata = {
      name      = "groq-llama"
      namespace = var.namespace
    }
    spec = {
      apiKeySecret    = kubernetes_secret_v1.groq.metadata[0].name
      apiKeySecretKey = "GROQ_API_KEY"
      model           = var.llm_model
      provider        = "OpenAI"
      openAI = {
        baseUrl = var.llm_base_url
      }
    }
  }

  depends_on = [helm_release.kagent_crds, kubernetes_secret_v1.groq]
}

# ── RemoteMCPServer — points kagent at the MCP tool server ───────────────────
resource "kubernetes_manifest" "remote_mcp_server" {
  manifest = {
    apiVersion = "kagent.dev/v1alpha2"
    kind       = "RemoteMCPServer"
    metadata = {
      name      = "kubeflow-docs-mcp"
      namespace = var.namespace
    }
    spec = {
      description = "MCP server for searching Kubeflow documentation via Feast and Milvus"
      url         = var.mcp_server_url
    }
  }

  depends_on = [helm_release.kagent_crds]
}

# ── Agent — the Kubeflow docs assistant ──────────────────────────────────────
# Binds the ModelConfig + RemoteMCPServer together with a system prompt that
# routes Kubeflow-specific questions through the search_kubeflow_docs tool.
resource "kubernetes_manifest" "agent" {
  manifest = {
    apiVersion = "kagent.dev/v1alpha2"
    kind       = "Agent"
    metadata = {
      name      = "kubeflow-docs-agent"
      namespace = var.namespace
    }
    spec = {
      description = "Kubeflow documentation assistant"
      type        = "Declarative"
      declarative = {
        modelConfig = kubernetes_manifest.model_config.manifest.metadata.name
        tools = [
          {
            type = "McpServer"
            mcpServer = {
              name      = kubernetes_manifest.remote_mcp_server.manifest.metadata.name
              kind      = "RemoteMCPServer"
              toolNames = ["search_kubeflow_docs"]
            }
          }
        ]
        systemMessage = <<-EOT
          You are the Kubeflow Docs Assistant.

          !!IMPORTANT!!
          - You should not use the tool calls directly from the user's input. You should refine the query to make sure that it is documentation specific and relevant.
          - You should never output the raw tool call to the user.

          Your role
          - Always answer the user's question directly.
          - If the question can be answered from general knowledge (e.g., greetings, small talk, generic programming/Kubernetes basics), respond without using tools.
          - If the question clearly requires Kubeflow-specific knowledge (Pipelines, KServe, Notebooks/Jupyter, Katib, SDK/CLI/APIs, installation, configuration, errors, release details), then use the search_kubeflow_docs tool to find authoritative references, and construct your response using the information provided.

          Tool Use
          - Use search_kubeflow_docs ONLY when Kubeflow-specific documentation is needed.
          - Do NOT use the tool for greetings, personal questions, small talk, or generic non-Kubeflow concepts.
          - When you do call the tool:
            - Use one clear, focused query.
            - Summarize the result in your own words.
            - If no results are relevant, say "not found in the docs" and suggest refining the query.

          Routing
          - Greetings/small talk: respond briefly, no tool.
          - Out-of-scope (sports, unrelated topics): politely say you only help with Kubeflow.
          - Kubeflow-specific: answer and call the tool if documentation is needed.

          Style
          - Be concise (2-5 sentences). Use bullet points or steps when helpful.
          - Provide examples only when asked.
          - Never invent features. If unsure, say so.
          - Reply in clean Markdown.
        EOT
      }
    }
  }

  depends_on = [
    helm_release.kagent,
    kubernetes_manifest.model_config,
    kubernetes_manifest.remote_mcp_server,
  ]
}
