# kubernetes_namespace_v1 is the current resource (v1 API, provider >= 3.x)
resource "kubernetes_namespace_v1" "docs_agent" {
  metadata {
    name = var.namespace

    labels = {
      # Disable Istio sidecar injection at the namespace level.
      # Individual pods (Milvus standalone) also set the annotation,
      # but the namespace label ensures nothing gets injected accidentally.
      "istio-injection" = "disabled"
    }
  }
}

resource "helm_release" "milvus" {
  name       = var.release_name
  repository = "https://zilliztech.github.io/milvus-helm/"
  chart      = "milvus"
  version    = var.chart_version
  namespace  = kubernetes_namespace_v1.docs_agent.metadata[0].name

  # Wait until all pods are Running before Terraform considers this done.
  # Milvus pulls several images on first install — 10 min is realistic.
  wait          = true
  wait_for_jobs = true
  timeout       = 600

  values = [
    yamlencode({
      # ── Mode ──────────────────────────────────────────────────────────
      # Standalone = single Milvus pod + embedded RocksMQ.
      # No distributed coordination, fits in ~2–3 GB.
      cluster = { enabled = false }

      # ── Message queue ─────────────────────────────────────────────────
      # Pulsar is the default MQ for cluster mode; disable both versions.
      # Standalone falls back to RocksMQ (embedded, zero extra pods).
      pulsar   = { enabled = false }
      pulsarv3 = { enabled = false }

      # ── etcd ──────────────────────────────────────────────────────────
      # One replica is enough for standalone. No PVC — data is ephemeral,
      # which is acceptable for a development deployment.
      etcd = {
        replicaCount = 1
        persistence  = { enabled = false }
      }

      # ── MinIO (object storage for segments) ───────────────────────────
      # Standalone MinIO, no PVC. Segment data is lost on pod restart —
      # the ETL pipeline re-populates Milvus, so this is acceptable in dev.
      minio = {
        mode        = "standalone"
        replicas    = 1
        persistence = { enabled = false }
      }

      # ── Milvus standalone pod ─────────────────────────────────────────
      standalone = {
        # Disable Istio sidecar: Milvus's internal gRPC calls during
        # startup conflict with Istio's mTLS before certs are ready.
        podAnnotations = {
          "sidecar.istio.io/inject" = "false"
        }

        # No PVC for RocksMQ data — ephemeral is fine for dev.
        # Without this, the chart creates a PVC that Helm's resource policy
        # keeps on uninstall, slowing namespace termination by ~60 seconds.
        persistence = { enabled = false }

        # Sized for OCI free tier: 2 nodes × 12 GB = 24 GB total.
        # Milvus standalone + MinIO + etcd target ~3–4 GB combined.
        resources = {
          requests = { memory = "1Gi", cpu = "500m" }
          limits   = { memory = "3Gi", cpu = "2" }
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace_v1.docs_agent]
}

# ── Istio AuthorizationPolicies ───────────────────────────────────────────────
# Required when the cluster runs Istio with a default-deny policy (full OKE
# cluster with Kubeflow installed). Without these, Istio blocks intra-namespace
# traffic to Milvus components even though pods are in the same namespace.
# Gated by var.istio_enabled — set false for local Docker Desktop testing.

resource "kubernetes_manifest" "allow_milvus_standalone" {
  count = var.istio_enabled ? 1 : 0

  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-milvus-standalone"
      namespace = var.namespace
    }
    spec = {
      selector = {
        matchLabels = {
          "app.kubernetes.io/name" = "milvus"
          component                = "standalone"
        }
      }
      action = "ALLOW"
      rules = [
        {
          to = [
            {
              operation = {
                ports = ["19530", "9091"]
              }
            }
          ]
        }
      ]
    }
  }

  depends_on = [helm_release.milvus]
}

resource "kubernetes_manifest" "allow_milvus_etcd" {
  count = var.istio_enabled ? 1 : 0

  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-milvus-etcd"
      namespace = var.namespace
    }
    spec = {
      selector = {
        matchLabels = {
          "app.kubernetes.io/name" = "etcd"
        }
      }
      action = "ALLOW"
      rules = [
        {
          to = [
            {
              operation = {
                ports = ["2379", "2380"]
              }
            }
          ]
        }
      ]
    }
  }

  depends_on = [helm_release.milvus]
}

resource "kubernetes_manifest" "allow_milvus_minio" {
  count = var.istio_enabled ? 1 : 0

  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "allow-milvus-minio"
      namespace = var.namespace
    }
    spec = {
      selector = {
        matchLabels = {
          app = "minio"
        }
      }
      action = "ALLOW"
      rules = [
        {
          to = [
            {
              operation = {
                ports = ["9000", "9001"]
              }
            }
          ]
        }
      ]
    }
  }

  depends_on = [helm_release.milvus]
}
