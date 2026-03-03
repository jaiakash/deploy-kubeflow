# ConfigMap — non-sensitive env vars the API server reads at startup.
# Variable names and defaults sourced from server-https/app.py in
# github.com/kubeflow/docs-agent.
resource "kubernetes_config_map_v1" "api_server" {
  metadata {
    name      = "docs-agent-api-config"
    namespace = var.namespace
  }

  data = {
    MILVUS_HOST         = var.milvus_host
    MILVUS_PORT         = tostring(var.milvus_port)
    MILVUS_COLLECTION   = "docs_rag"
    MILVUS_VECTOR_FIELD = "vector"
    # Must match the model used when the ETL pipeline embedded the docs.
    EMBEDDING_MODEL  = "sentence-transformers/all-mpnet-base-v2"
    MODEL            = var.llm_model
    PORT             = "8000"
    PYTHONUNBUFFERED = "1"
  }
}

# Secret — LLM endpoint URL and API key must not appear in plan output or logs.
# KSERVE_URL is the env var name the docs-agent reads regardless of whether
# the backend is KServe (internal) or an external provider like Groq.
resource "kubernetes_secret_v1" "api_server" {
  metadata {
    name      = "docs-agent-api-secret"
    namespace = var.namespace
  }

  data = {
    KSERVE_URL  = var.llm_endpoint
    LLM_API_KEY = var.llm_api_key
  }
}

resource "kubernetes_deployment_v1" "api_server" {
  metadata {
    name      = "docs-agent-api"
    namespace = var.namespace
    labels    = { app = "docs-agent-api" }
  }

  spec {
    replicas = var.replicas

    # Rolling update with zero downtime — never take the pod down before
    # the new one is ready.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "0"
        max_surge       = "1"
      }
    }

    selector {
      match_labels = { app = "docs-agent-api" }
    }

    template {
      metadata {
        labels = { app = "docs-agent-api" }
        annotations = {
          # Disable Istio sidecar — plain gRPC to Milvus; mTLS would require
          # additional PeerAuthentication config out of scope here.
          "sidecar.istio.io/inject" = "false"
        }
      }

      spec {
        container {
          name  = "https-api"
          image = var.image

          # IfNotPresent: don't re-pull on every pod restart.
          # Use a versioned tag (not :latest) in production to make
          # rollbacks reliable.
          image_pull_policy = "IfNotPresent"

          port {
            name           = "http"
            container_port = 8000
            protocol       = "TCP"
          }

          # All non-sensitive config injected as a block.
          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.api_server.metadata[0].name
            }
          }

          # Sensitive values injected individually — Kubernetes stores
          # Secrets encrypted at rest and redacts them from pod describe.
          env {
            name = "KSERVE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.api_server.metadata[0].name
                key  = "KSERVE_URL"
              }
            }
          }

          env {
            name = "LLM_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.api_server.metadata[0].name
                key  = "LLM_API_KEY"
              }
            }
          }

          # Readiness: hold traffic until /health returns 200.
          # Prevents cold-start requests from hitting a pod that hasn't
          # connected to Milvus yet.
          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }

          # Liveness: restart the pod if it stops responding.
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          # Resources sourced from upstream server-https/deployment.yaml.
          resources {
            requests = {
              cpu               = "200m"
              memory            = "512Mi"
              ephemeral-storage = "2Gi"
            }
            limits = {
              cpu               = "1000m"
              memory            = "1Gi"
              ephemeral-storage = "4Gi"
            }
          }

          # Security context mirrors the non-root user created in the
          # Dockerfile (useradd -m -u 1000 appuser).
          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 1000
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_config_map_v1.api_server,
    kubernetes_secret_v1.api_server,
  ]
}

# ClusterIP service — reachable inside the cluster at:
#   docs-agent-api.<namespace>.svc.cluster.local:8000
# Pair with an Istio VirtualService for external access once the full
# Kubeflow stack is deployed.
resource "kubernetes_service_v1" "api_server" {
  metadata {
    name      = "docs-agent-api"
    namespace = var.namespace
  }

  spec {
    selector = { app = "docs-agent-api" }

    port {
      name        = "http"
      port        = 8000
      target_port = 8000
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}
