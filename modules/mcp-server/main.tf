# ConfigMap — non-sensitive config the MCP server reads at startup.
# Note: server.py currently hardcodes these values. The image should be
# built to read from env vars (os.getenv) so this ConfigMap takes effect.
resource "kubernetes_config_map_v1" "mcp_server" {
  metadata {
    name      = "mcp-server-config"
    namespace = var.namespace
  }

  data = {
    MILVUS_URI       = "http://${var.milvus_host}:${var.milvus_port}"
    MILVUS_USER      = "root"
    COLLECTION_NAME  = "kubeflow_docs_docs_rag"
    EMBEDDING_MODEL  = "sentence-transformers/all-mpnet-base-v2"
    PORT             = "8000"
    PYTHONUNBUFFERED = "1"
  }
}

# Secret — Milvus password is sensitive; default Milvus install uses "Milvus".
resource "kubernetes_secret_v1" "mcp_server" {
  metadata {
    name      = "mcp-server-secret"
    namespace = var.namespace
  }

  data = {
    MILVUS_PASSWORD = var.milvus_password
  }
}

resource "kubernetes_deployment_v1" "mcp_server" {
  metadata {
    name      = "mcp-kubeflow-docs"
    namespace = var.namespace
    labels    = { app = "mcp-kubeflow-docs" }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = { app = "mcp-kubeflow-docs" }
    }

    template {
      metadata {
        labels = { app = "mcp-kubeflow-docs" }
      }

      spec {
        container {
          name              = "mcp-server"
          image             = var.image
          image_pull_policy = "IfNotPresent"

          port {
            name           = "mcp"
            container_port = 8000
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.mcp_server.metadata[0].name
            }
          }

          env {
            name = "MILVUS_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mcp_server.metadata[0].name
                key  = "MILVUS_PASSWORD"
              }
            }
          }

          # TCP probe — FastMCP uses streamable-http transport, no plain /health.
          # TCP check confirms the port is bound and accepting connections.
          readiness_probe {
            tcp_socket {
              port = 8000
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          liveness_probe {
            tcp_socket {
              port = 8000
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_config_map_v1.mcp_server,
    kubernetes_secret_v1.mcp_server,
  ]
}

# ClusterIP — kagent references this via RemoteMCPServer at:
#   http://mcp-kubeflow-docs.<namespace>.svc.cluster.local:8000/mcp
resource "kubernetes_service_v1" "mcp_server" {
  metadata {
    name      = "mcp-kubeflow-docs"
    namespace = var.namespace
  }

  spec {
    selector = { app = "mcp-kubeflow-docs" }

    port {
      name        = "mcp"
      port        = 8000
      target_port = 8000
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}
