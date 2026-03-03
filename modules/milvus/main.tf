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
