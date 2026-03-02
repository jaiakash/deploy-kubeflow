# Implementation Plan — Kubeflow Docs-Agent Terraform Infrastructure

> **Repo:** `jaiakash/deploy-kubeflow`
> **Scope:** Terraform infrastructure to deploy the docs-agent stack on OCI (Oracle Cloud Infrastructure)

---

## Table of Contents

1. [Project Context](#1-project-context)
2. [Key Decisions & Rationale](#2-key-decisions--rationale)
3. [Architecture Overview](#3-architecture-overview)
4. [Phase-wise Implementation Plan](#4-phase-wise-implementation-plan)
5. [Module Contracts](#5-module-contracts)
6. [Variable Reference](#6-variable-reference)
7. [Risk Register](#7-risk-register)

---

## 1. Project Context

The docs-agent is a RAG-powered chatbot that answers questions across Kubeflow documentation. It consists of:

- A **FastAPI server** that accepts `/chat` and `/health` requests
- A **Milvus vector database** that stores chunked, embedded documentation
- **Kubeflow Pipelines** that run the ETL (fetch → chunk → embed → store)
- An **LLM** (external API in dev, KServe on-cluster in prod)

This repo handles only the **infrastructure and deployment** via Terraform. The application code (API server, pipeline definitions) lives in a separate repository.

---

## 2. Key Decisions & Rationale

### Decision 1 — Hybrid Terraform approach (Kustomize + native TF)

Three options were evaluated for installing Kubeflow:

| Option | Approach | Why rejected / chosen |
|--------|----------|----------------------|
| A | `null_resource` + `local-exec` for everything | TF can't track K8s state; destroy is unreliable |
| B | `kubernetes_manifest` for all 200+ KF resources | Maintenance nightmare; fights Kustomize |
| **C (chosen)** | Kustomize for KF platform, native TF for docs-agent stack | Best of both: official install method for KF, full TF tracking for our custom stack |

**Result:** The `kubeflow-platform` module is a thin `null_resource` wrapper around the official `kustomize build | kubectl apply` workflow. Everything else (Milvus, RBAC, API server, KServe) uses native Terraform providers with full state tracking.

---

### Decision 2 — OCI Always Free Tier

| Resource | Spec | Reason |
|----------|------|--------|
| Compute | ARM Ampere A1 Flex | Only free option with enough RAM |
| Node layout | 2 nodes × (2 OCPU + 12 GB) | HA; fits within 4 OCPU / 24 GB free allowance |
| Boot volume | 50 GB each (200 GB total pool) | Free tier limit |
| Object Storage | 20 GB — Terraform state backend | Free tier; S3-compat API |
| Load Balancer | 1 Flexible LB (10 Mbps) | Free tier; exposes Istio ingress |
| GPU | None | Not available on free tier |

---

### Decision 3 — LLM strategy: external API now, KServe later

| Mode | When | How |
|------|------|-----|
| External API (default) | Development / free tier | `var.external_llm_endpoint` → Groq or Together.ai (free Llama 3.1 endpoints) |
| KServe InferenceService | Production / GPU cluster | `var.deploy_kserve = true` → KServe + vLLM + Llama 3.1-8B |

The API server accepts any OpenAI-compatible endpoint — switching from Groq to KServe is a single variable change, no code change required.

`deploy_kserve` defaults to `false`. The `kserve-llm` module uses `count = var.deploy_kserve ? 1 : 0` so GPU resources are never provisioned accidentally.

---

### Decision 4 — Stripped-down Kubeflow component set

Full Kubeflow exceeds 24 GB RAM. For start , we install only what the docs-agent needs. Later we can add other kubeflow components:

| Component | Install? | Reason |
|-----------|----------|--------|
| cert-manager | Yes | Required by Istio, KServe |
| Istio (CNI) | Yes | Service mesh; required by KF Pipelines |
| Dex + oauth2-proxy | Yes | Authentication for Central Dashboard |
| Knative Serving | Yes | Required by KServe |
| KServe | Yes | Model serving (used in prod mode) |
| Kubeflow Pipelines | Yes | ETL for documentation ingestion |
| Central Dashboard | Yes | UI; useful for monitoring pipelines |
| Profiles + RBAC | Yes | Namespace isolation |
| Katib | No | Hyperparameter tuning — not needed |
| Training Operator | No | Distributed training — not needed |
| Notebooks | No | JupyterHub — not needed |
| Spark Operator | No | Not needed |
| Tensorboard | No | Not needed |
| Volumes Manager | No | Not needed |

---

### Decision 5 — Remote state in OCI Object Storage

Terraform's `s3` backend is pointed at OCI Object Storage's S3-compatible API. Credentials are passed via env vars (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` set to OCI Customer Secret Key values), never in code.

Four flags disable AWS-specific validation checks that fail on OCI:
- `skip_region_validation = true`
- `skip_credentials_validation = true`
- `skip_metadata_api_check = true`
- `force_path_style = true`

---

### Decision 6 — GitOps (ArgoCD) deferred to Phase 2

Chase suggested ArgoCD for GitOps. This is planned but deferred. The hybrid approach naturally supports migration:
- **Today:** TF `null_resource` → kustomize → installs KF
- **Future:** TF → installs ArgoCD → ArgoCD syncs KF manifests from Git

No architectural changes needed when ArgoCD is added — it slots in as an additional module.

---

## 3. Architecture Overview

### Component stack

```
┌──────────────────────────────────────────────────┐
│  Layer 5: API Server (FastAPI, port 8000)        │  ~256 MB
│  Endpoints: /chat (POST), /health (GET)          │
├──────────────────────────────────────────────────┤
│  Layer 4: KServe / External LLM                  │
│  Dev: Groq/Together.ai (external, free)          │
│  Prod: KServe + vLLM + Llama 3.1-8B              │
├──────────────────────────────────────────────────┤
│  Layer 3: Kubeflow Pipelines (ETL)               │
│  Fetches docs → chunks → embeds → stores         │
├──────────────────────────────────────────────────┤
│  Layer 2: Milvus Vector DB (Helm, standalone)    │  ~2–3 GB
│  Collection: docs_rag, port 19530                │
├──────────────────────────────────────────────────┤
│  Layer 1: Kubeflow Platform (Kustomize)          │  ~6–8 GB
│  Istio, Pipelines, KServe, cert-manager, Dex     │
├──────────────────────────────────────────────────┤
│  Layer 0: OKE Cluster                            │
│  2 ARM nodes × (2 OCPU + 12 GB)                  │
└──────────────────────────────────────────────────┘
```

### Terraform module dependency chain

```
OKE cluster
    └──► kubeflow-platform   (null_resource + kustomize)
              ├──► milvus    (helm_release, standalone)
              ├──► rbac      (Role + RoleBinding)
              ├──► api-server (Deployment + Service + ConfigMap)
              └──► kserve-llm (count=0 by default, GPU required)
```

### Runtime data flow

```
User Query
    │
    ▼
API Server ──► LLM (Groq or KServe)
    │                │
    │        [Tool: search_kubeflow_docs]
    │                │
    │                ▼
    │          Milvus (vector search)
    │                │
    │          [Top-K chunks + citations]
    ▼                ▼
User Response + Citations
```

---

## 4. Phase-wise Implementation Plan

### Phase 1 — Skeleton

**Goal:** `terraform init` and `terraform validate` pass on a clean machine. No cloud resources created.

**Files created:**

| File | Purpose |
|------|---------|
| `providers.tf` | Declares `oci`, `kubernetes`, `helm` providers with version floors |
| `variables.tf` | All input variables across all layers, with defaults and `sensitive` markers |
| `main.tf` | Root orchestration — calls all modules in dependency order |
| `outputs.tf` | Exposes `api_endpoint`, `milvus_host/port`, `kserve_endpoint` |
| `backend.tf` | OCI Object Storage remote state (S3-compat backend) |
| `.gitignore` | Excludes `.tfstate`, `*.tfvars`, `.terraform/`, `*.pem` |
| `terraform.tfvars.example` | Fill-in-the-blanks template for collaborators |
| `modules/*/main.tf` | Stubs — comment explaining what each module will do |
| `modules/*/variables.tf` | Fully defined — all inputs declared |
| `modules/*/outputs.tf` | Placeholder outputs with computed DNS names |

**Test checklist:**
- [ ] `terraform init -backend=false` — all modules found, providers downloaded
- [ ] `terraform validate` — configuration is valid
- [ ] `terraform plan -var="..."` — no changes (stubs are empty), no errors
- [ ] `terraform plan -var="deploy_kserve=true"` — kserve_llm[0] appears
- [ ] `git check-ignore -v terraform.tfvars` — correctly ignored
- [ ] `git check-ignore -v terraform.tfvars.example` — NOT ignored
- [ ] `terraform fmt -check -recursive` — all files correctly formatted

---

### Phase 2 — Milvus Module

**Goal:** `terraform apply` creates a working Milvus standalone instance. `terraform destroy` removes it cleanly.

**Files to implement:**
- `modules/milvus/main.tf` — `kubernetes_namespace` + `helm_release`

**Key implementation details:**
- Chart: `milvus/milvus` from `https://zilliztech.github.io/milvus-helm/`
- Mode: standalone (not cluster) — fits within 24 GB, matches docs-agent README
- Persistence: disabled for dev (`etcd.persistence.enabled = false`)
- Pulsar: disabled (`pulsar.enabled = false`, `pulsarv3.enabled = false`)
- Istio sidecar: disabled on standalone pod (`sidecar.istio.io/inject: "false"`) — avoids mTLS issues during init

**Test:** `python -c "from pymilvus import connections; connections.connect(...)"` returns connected.

---

### Phase 3 — RBAC Module

**Goal:** Kubeflow Pipelines service account can reach Milvus services.

**Files to implement:**
- `modules/rbac/main.tf` — `kubernetes_role` + `kubernetes_role_binding`

**Key implementation details:**
- Role grants `get`, `list`, `watch` on `services` and `endpoints` in `docs-agent` namespace
- RoleBinding binds to `serviceaccount/default-editor` in `kubeflow` namespace
- This is the service account KFP uses when running pipeline steps

**Test:** `kubectl auth can-i list services --as=system:serviceaccount:kubeflow:default-editor -n docs-agent`

---

### Phase 4 — API Server Module

**Goal:** `/health` returns 200, `/chat` returns a response from the external LLM.

**Files to implement:**
- `modules/api-server/main.tf` — `kubernetes_deployment` + `kubernetes_service` + `kubernetes_config_map` + `kubernetes_secret`

**Key implementation details:**
- ConfigMap sets: `MILVUS_HOST`, `MILVUS_PORT`, `MILVUS_COLLECTION`, `EMBEDDING_MODEL`, `MODEL`, `PORT`
- Secret sets: `KSERVE_URL` (LLM endpoint), `LLM_API_KEY`
- Service: ClusterIP initially; add LoadBalancer or Istio VirtualService for external access
- Resource requests: `256Mi` memory, `250m` CPU (small footprint)

**Test:**
```bash
kubectl port-forward svc/docs-agent-api -n docs-agent 8000:8000
curl http://localhost:8000/health
```

---

### Phase 5 — KServe LLM Module (write, don't apply yet)

**Goal:** Module is written and plan-testable with `deploy_kserve = false`. Ready to activate when a GPU node is available.

**Files to implement:**
- `modules/kserve-llm/main.tf` — `kubernetes_secret` (HF token) + `kubernetes_manifest` (ServingRuntime + InferenceService)
- `modules/kserve-llm/manifests/serving-runtime.yaml`
- `modules/kserve-llm/manifests/inference-service.yaml`

**Key implementation details:**
- ServingRuntime: `kserve/huggingfaceserver:latest-gpu`, requests `nvidia.com/gpu: 1`
- InferenceService: model from HuggingFace, backend `vllm`, context length 32768
- `count = var.deploy_kserve ? 1 : 0` — zero resources when GPU not available
- HF token stored in a `kubernetes_secret`, referenced via `secretKeyRef`

**Test:** `terraform plan -var="deploy_kserve=false"` → no KServe resources in plan.

---

### Phase 6 — Kubeflow Platform Module 

**Goal:** Full `terraform apply` from bare OKE cluster to running Kubeflow + docs-agent stack.

**Files to implement:**
- `modules/kubeflow-platform/main.tf` — `null_resource` with `local-exec` create and destroy provisioners
- `scripts/install-kubeflow.sh` — loops through `kf_components`, applies each via kustomize with retry logic
- `scripts/configure-kubectl.sh` — helper to set up kubeconfig from OCI

**Key implementation details:**
- Install script clones `github.com/kubeflow/manifests` at `var.kf_version`
- Applies components in order with `kubectl apply -k` and a retry loop (CRDs need time to establish)
- Destroy provisioner runs `kubectl delete -k` in reverse order
- `triggers` on `kf_version` and `kf_components` hash — forces reinstall when either changes

**Test:** `kubectl get pods -n kubeflow` — all pods Running/Completed.

---

### Phase 7 — Documentation & Cleanup

**Goal:** Repo is ready for handoff and CI.

**Deliverables:**
- `docs/REQUIREMENTS.md` — full functional and non-functional requirements
- `README.md` — quickstart guide (prerequisites → clone → init → apply)
- `scripts/verify.sh` — post-deploy health check script
- Full destroy + re-apply cycle verified

---
