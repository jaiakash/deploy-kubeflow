# HuggingFace token — needed to pull gated models (Llama 3.1 requires HF access approval).
# Stored as a K8s Secret so it never appears in pod logs or describe output.
resource "kubernetes_secret_v1" "huggingface" {
  metadata {
    name      = "huggingface-secret"
    namespace = var.namespace
  }

  data = {
    token = var.huggingface_token
  }
}

# ServingRuntime — defines the vLLM-backed container template for HuggingFace models.
# Reusable across InferenceServices; selected by name in the InferenceService below.
# Requires KServe CRDs to be installed (done by the kubeflow-platform module).
resource "kubernetes_manifest" "serving_runtime" {
  manifest = {
    apiVersion = "serving.kserve.io/v1alpha1"
    kind       = "ServingRuntime"
    metadata = {
      name      = "llm-runtime"
      namespace = var.namespace
    }
    spec = {
      supportedModelFormats = [
        {
          name       = "huggingface"
          version    = "1"
          autoSelect = true
        }
      ]
      containers = [
        {
          name    = "kserve-container"
          image   = "kserve/huggingfaceserver:latest-gpu"
          command = ["python", "-m", "huggingfaceserver"]
          resources = {
            requests = {
              cpu              = "4"
              memory           = "16Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              cpu              = "6"
              memory           = "24Gi"
              "nvidia.com/gpu" = "1"
            }
          }
        }
      ]
    }
  }

  depends_on = [kubernetes_secret_v1.huggingface]
}

# InferenceService — deploys Llama 3.1-8B using the ServingRuntime above.
# vLLM backend with tool-calling enabled — required for the docs-agent
# search_kubeflow_docs function call to work correctly.
resource "kubernetes_manifest" "inference_service" {
  manifest = {
    apiVersion = "serving.kserve.io/v1beta1"
    kind       = "InferenceService"
    metadata = {
      name      = "llama"
      namespace = var.namespace
    }
    spec = {
      predictor = {
        model = {
          modelFormat = {
            name    = "huggingface"
            version = "1"
          }
          runtime = "llm-runtime"
          args = [
            "--model_name=llama3.1-8B",
            "--model_id=${var.model_id}",
            "--backend=vllm",
            "--max-model-len=32768",
            "--gpu-memory-utilization=0.90",
            "--enable-auto-tool-choice",
            "--tool-call-parser=llama3_json",
            "--enable-tool-call-parser",
          ]
          env = [
            {
              name = "HF_TOKEN"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret_v1.huggingface.metadata[0].name
                  key  = "token"
                }
              }
            },
            {
              name  = "CUDA_VISIBLE_DEVICES"
              value = "0"
            }
          ]
          resources = {
            requests = {
              cpu              = "4"
              memory           = "16Gi"
              "nvidia.com/gpu" = "1"
            }
            limits = {
              cpu              = "6"
              memory           = "24Gi"
              "nvidia.com/gpu" = "1"
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.serving_runtime]
}
