# ETL Pipeline — Kubernetes Job that crawls Kubeflow docs,
# chunks, embeds, and writes vectors to Milvus.

# ConfigMap — non-sensitive pipeline parameters.
resource "kubernetes_config_map_v1" "etl_pipeline" {
  metadata {
    name      = "etl-pipeline-config"
    namespace = var.namespace
  }

  data = {
    MILVUS_HOST      = var.milvus_host
    MILVUS_PORT      = tostring(var.milvus_port)
    MILVUS_USER      = "root"
    COLLECTION_NAME  = var.collection_name
    EMBEDDING_MODEL  = var.embedding_model
    GITHUB_REPO      = var.github_repo
    GITHUB_DOCS_PATH = var.github_docs_path
    CHUNK_SIZE       = tostring(var.chunk_size)
    CHUNK_OVERLAP    = tostring(var.chunk_overlap)
  }
}

# Secret — credentials that should not appear in ConfigMap.
resource "kubernetes_secret_v1" "etl_pipeline" {
  metadata {
    name      = "etl-pipeline-secret"
    namespace = var.namespace
  }

  data = {
    MILVUS_PASSWORD = var.milvus_password
    GITHUB_TOKEN    = var.github_token
  }
}

# Job — runs once, blocks terraform apply until complete (30 min timeout).
# To re-index: taint this resource and re-apply.
resource "kubernetes_job_v1" "etl_pipeline" {
  metadata {
    name      = "etl-pipeline"
    namespace = var.namespace
    labels    = { app = "etl-pipeline" }
  }

  spec {
    backoff_limit              = var.backoff_limit
    ttl_seconds_after_finished = var.ttl_seconds_after_finished

    template {
      metadata {
        labels = { app = "etl-pipeline" }
        annotations = {
          # Jobs with Istio sidecars never complete — the sidecar keeps running.
          "sidecar.istio.io/inject" = "false"
        }
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name              = "etl"
          image             = var.image
          image_pull_policy = "IfNotPresent"

          # Bulk config from ConfigMap
          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.etl_pipeline.metadata[0].name
            }
          }

          # Sensitive values from Secret
          env {
            name = "MILVUS_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.etl_pipeline.metadata[0].name
                key  = "MILVUS_PASSWORD"
              }
            }
          }

          env {
            name = "GITHUB_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.etl_pipeline.metadata[0].name
                key  = "GITHUB_TOKEN"
              }
            }
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "30m"
  }

  depends_on = [
    kubernetes_config_map_v1.etl_pipeline,
    kubernetes_secret_v1.etl_pipeline,
  ]
}
