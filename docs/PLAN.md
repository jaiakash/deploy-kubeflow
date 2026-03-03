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

### Phase 1 — Skeleton ✅ COMPLETE

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

### Phase 2 — Milvus Module ✅ COMPLETE (tested on Docker Desktop)

**Goal:** `terraform apply` creates a working Milvus standalone instance. `terraform destroy` removes it cleanly.

**Files implemented:**
- `modules/milvus/main.tf` — `kubernetes_namespace_v1` + `helm_release`

**Helm chart:**
- Repo: `https://zilliztech.github.io/milvus-helm/`
- Chart: `milvus`, version `4.2.7`
- Deployed Milvus `v2.4.9`

**Helm values used:**

| Key | Value | Reason |
|-----|-------|--------|
| `cluster.enabled` | `false` | Standalone mode — single pod, no ZooKeeper |
| `pulsar.enabled` | `false` | Standalone falls back to embedded RocksMQ |
| `pulsarv3.enabled` | `false` | Same — disable both Pulsar versions |
| `etcd.replicaCount` | `1` | One replica sufficient for standalone |
| `etcd.persistence.enabled` | `false` | Ephemeral — acceptable for dev |
| `minio.mode` | `standalone` | Single MinIO instance |
| `minio.persistence.enabled` | `false` | Ephemeral object storage |
| `standalone.persistence.enabled` | `false` | Prevents PVC for RocksMQ data (see issues below) |
| `standalone.podAnnotations` | `sidecar.istio.io/inject: "false"` | Avoids Istio mTLS conflict during gRPC init |
| `standalone.resources.requests` | `1Gi / 500m` | Sized for 24 GB OCI free tier |
| `standalone.resources.limits` | `3Gi / 2 CPU` | Headroom for peak usage |

**Why `yamlencode({...})` instead of `set {}` blocks:**
Helm `set` blocks use dot-notation paths — keys with dots in them (e.g., `sidecar.istio.io/inject`) require escaping and become error-prone. A single `values` block with `yamlencode` handles arbitrary key names cleanly and keeps the config readable as a unified structure.

**Provider fixes discovered during implementation:**
| Issue | Fix |
|-------|-----|
| `kubernetes_namespace` deprecated in provider v3 | Changed to `kubernetes_namespace_v1` |
| Helm provider v3 changed `kubernetes {}` block to assignment | Changed to `kubernetes = {}` |

**Local testing setup:**
The `backend.tf` S3 backend blocks `terraform apply` without an OCI bucket. For local testing, create `backend_override.tf` (already gitignored via `*_override.tf` pattern):
```hcl
terraform {
  backend "local" {}
}
```
Then run `terraform init -reconfigure`. Delete this file when connecting to the real OCI backend.

**Issues found and fixed:**

1. **PVC leftover on destroy (first run):** Helm uninstall kept a `PersistentVolumeClaim` for the Milvus standalone pod's RocksMQ data due to the chart's `helm.sh/resource-policy: keep` annotation. The namespace deletion eventually cleaned it up (~53 s wait), but it caused an unnecessary delay and a warning.
   - **Fix:** Added `standalone.persistence.enabled = false` to the Helm values. No PVC is created, destroy is clean.

**Test results (Docker Desktop — 7.8 GB RAM, 10 CPU):**

| Test | Result |
|------|--------|
| `terraform apply -target=module.milvus` | ✅ 2 resources created (1m41s, images cached) |
| `kubectl get pods -n docs-agent` | ✅ `milvus-standalone`, `etcd-0`, `minio` all `1/1 Running` |
| `kubectl get svc -n docs-agent` | ✅ `my-release-milvus` ClusterIP on port `19530/9091` |
| pymilvus connection test | ✅ `Connected! version: v2.4.9, collections: []` |
| `terraform destroy -target=module.milvus` | ✅ 2 resources destroyed, no PVC warning, namespace gone in 43s |

**Test commands:**
```bash
# Apply
terraform apply -target=module.milvus -var="kubeconfig_path=~/.kube/config" ...

# Verify pods
kubectl get pods -n docs-agent

# Connectivity test
kubectl port-forward svc/my-release-milvus -n docs-agent 19530:19530 &
python3 -c "
from pymilvus import connections, utility
connections.connect('default', host='localhost', port='19530')
print('Connected! version:', utility.get_server_version())
"

# Teardown
terraform destroy -target=module.milvus ...
```

---

### Phase 3 — RBAC Module ✅ COMPLETE (tested on Docker Desktop)

**Goal:** Kubeflow Pipelines service account can reach Milvus services.

**Files implemented:**
- `modules/rbac/main.tf` — `kubernetes_role_v1` + `kubernetes_role_binding_v1`
- `modules/rbac/outputs.tf` — exposes `role_name`, `role_binding_name`

**Resources created:**

| Resource | Name | Namespace |
|----------|------|-----------|
| `kubernetes_role_v1` | `milvus-access` | `docs-agent` |
| `kubernetes_role_binding_v1` | `kfp-to-milvus-editor` | `docs-agent` |

**Role rules:**
```
api_groups: [""]          ← core API group (services, endpoints live here)
resources:  [services, endpoints]
verbs:      [get, list, watch]
```

**RoleBinding subject:**
```
kind:      ServiceAccount
name:      default-editor     ← KFP's pipeline step runner SA
namespace: kubeflow            ← cross-namespace binding (valid in K8s)
```

**Why `api_groups = [""]`:**
Empty string is the Kubernetes core API group — not a mistake. Services and endpoints are core/v1 resources. Named API groups (`apps`, `batch`, etc.) apply to higher-level resources like Deployments and Jobs.

**Why cross-namespace RoleBinding:**
KFP runs pipeline step pods in the `kubeflow` namespace using the `default-editor` service account. The Milvus service lives in `docs-agent`. A RoleBinding in `docs-agent` can reference a subject (service account) from any namespace — Kubernetes supports this by design.

**Destroy order (Terraform-managed):**
Terraform correctly destroys RoleBinding before Role (dependency order), then Helm release, then namespace — no manual ordering needed.

**Test results (Docker Desktop):**

| Test | Command | Expected | Result |
|------|---------|----------|--------|
| Apply | `terraform apply -target=module.milvus -target=module.rbac` | 4 resources created | ✅ |
| Role exists | `kubectl get role milvus-access -n docs-agent` | Role present | ✅ |
| RoleBinding exists | `kubectl get rolebinding kfp-to-milvus-editor -n docs-agent` | Bound to `kubeflow/default-editor` | ✅ |
| Allowed: list services | `kubectl auth can-i list services --as=system:serviceaccount:kubeflow:default-editor -n docs-agent` | `yes` | ✅ |
| Allowed: get endpoints | `kubectl auth can-i get endpoints --as=system:serviceaccount:kubeflow:default-editor -n docs-agent` | `yes` | ✅ |
| Denied: create pods | `kubectl auth can-i create pods --as=system:serviceaccount:kubeflow:default-editor -n docs-agent` | `no` | ✅ |
| Denied: cross-namespace | `kubectl auth can-i list services --as=system:serviceaccount:kubeflow:default-editor -n kube-system` | `no` | ✅ |
| Destroy | `terraform destroy -target=module.rbac -target=module.milvus` | 4 resources destroyed, namespace gone in 13s | ✅ |

---

### Phase 4 — MCP Server + kagent 

> **Architecture change (confirmed by Santosh):** The `server-https` FastAPI server is deprecated. The new approach uses [`kagent-feast-mcp`](https://github.com/kubeflow/docs-agent/tree/main/kagent-feast-mcp) — a FastMCP tool server + kagent agent framework.

#### Why the architecture changed

| | Old (`server-https`) | New (`kagent-feast-mcp`) |
|-|----------------------|--------------------------|
| User interface | curl `/chat` endpoint | kagent UI (port-forwarded) |
| LLM orchestration | FastAPI calls Groq directly | kagent `Agent` CRD manages routing |
| Tool protocol | Custom function call in app.py | MCP (Model Context Protocol) |
| Milvus access | Direct from API server | Via MCP server `search_kubeflow_docs` tool |
| Vector store pipeline | Milvus native | KFP pipeline → Feast → Milvus |
| Collection name | `docs_rag` | `kubeflow_docs_docs_rag` (Feast naming) |

#### New architecture

```
User
  │
  ▼
kagent UI (port 8080)
  │
  ▼
kagent Agent CRD ──► Groq LLM (ModelConfig)
  │
  │  [Tool call: search_kubeflow_docs]
  ▼
MCP Server (FastMCP, port 8000/mcp)
  │
  ▼
Milvus (kubeflow_docs_docs_rag collection)
```

#### What was deleted

- `modules/api-server/` — removed entirely

#### What was implemented

**`modules/mcp-server/`** — replaces `api-server`

| Resource | Name |
|----------|------|
| `kubernetes_config_map_v1` | `mcp-server-config` |
| `kubernetes_secret_v1` | `mcp-server-secret` |
| `kubernetes_deployment_v1` | `mcp-kubeflow-docs` |
| `kubernetes_service_v1` | `mcp-kubeflow-docs` |

- ConfigMap injects: `MILVUS_URI`, `MILVUS_USER`, `COLLECTION_NAME`, `EMBEDDING_MODEL`, `PORT`
- Secret injects: `MILVUS_PASSWORD` (sensitive)
- TCP readiness/liveness probes — FastMCP has no plain `/health` endpoint
- Resources: requests 500m/1Gi, limits 1CPU/2Gi
- Output: `mcp_endpoint` = `http://mcp-kubeflow-docs.<namespace>.svc.cluster.local:8000/mcp`

**`modules/kagent/`** — new

| Resource | Kind | Name |
|----------|------|------|
| `helm_release` | Helm | `kagent-crds` |
| `helm_release` | Helm | `kagent` |
| `kubernetes_secret_v1` | Secret | `kagent-groq` |
| `kubernetes_manifest` | `ModelConfig` | `groq-llama` |
| `kubernetes_manifest` | `RemoteMCPServer` | `kubeflow-docs-mcp` |
| `kubernetes_manifest` | `Agent` | `kubeflow-docs-agent` |

- kagent Helm charts from `oci://ghcr.io/kagent-dev/kagent/helm/`
- All built-in agents disabled (only our custom `Agent` CRD is active)
- `ModelConfig` uses `kagent.dev/v1alpha2` API, provider=OpenAI, baseUrl=Groq
- `RemoteMCPServer` points to MCP server in-cluster URL
- `Agent` includes the full system prompt with Kubeflow routing rules

**`modules/milvus/` additions** — Istio AuthorizationPolicies

Three `security.istio.io/v1beta1` `AuthorizationPolicy` resources, gated by `var.istio_enabled`:

| Policy | Target | Ports |
|--------|--------|-------|
| `allow-milvus-standalone` | Milvus pod | 19530, 9091 |
| `allow-milvus-etcd` | etcd pod | 2379, 2380 |
| `allow-milvus-minio` | MinIO pod | 9000, 9001 |

Required on OCI cluster (Kubeflow installs Istio with default-deny). Set `istio_enabled = false` for local Docker Desktop testing.

#### Pending — waiting on Santosh

- **MCP server image** — needs to be built from [`kagent-feast-mcp/mcp-server/`](https://github.com/kubeflow/docs-agent/tree/main/kagent-feast-mcp/mcp-server) and published
- **`server.py` env var support** — currently hardcodes `MILVUS_URI`, `MILVUS_USER` etc. as module-level constants. Needs to read from `os.getenv()` for the Terraform ConfigMap to take effect
- Once image is available: set `var.mcp_image` and run end-to-end test on OCI cluster

#### Test commands (once image is ready)
```bash
terraform apply \
  -target=module.milvus \
  -target=module.rbac \
  -target=module.mcp_server \
  -target=module.kagent \
  -var="mcp_image=<registry>/mcp-kubeflow-docs:<tag>" \
  -var="groq_api_key=<key>" \
  -var="istio_enabled=false"   # for local; true on OCI

# Access kagent UI
kubectl -n docs-agent port-forward service/kagent-ui 8080:8080
# Open http://localhost:8080
```

---

### Phase 5 — KServe LLM Module ✅ COMPLETE (plan-tested, apply requires GPU + KServe)

**Goal:** Module is written and plan-testable with `deploy_kserve = false`. Ready to activate when a GPU node is available.

**Files implemented:**
- `modules/kserve-llm/main.tf` — `kubernetes_secret_v1` (HF token) + `kubernetes_manifest` (ServingRuntime + InferenceService)

**Resources created (when `deploy_kserve = true`):**

| Resource | Kind | Name |
|----------|------|------|
| `kubernetes_secret_v1` | Secret | `huggingface-secret` |
| `kubernetes_manifest` | `ServingRuntime` | `llm-runtime` |
| `kubernetes_manifest` | `InferenceService` | `llama` |

**ServingRuntime spec:**
- Image: `kserve/huggingfaceserver:latest-gpu`
- Command: `python -m huggingfaceserver`
- Resources: 4 CPU / 16 Gi memory / 1 GPU (requests), 6 CPU / 24 Gi / 1 GPU (limits)

**InferenceService spec:**
- Model: `var.model_id` (default: `RedHatAI/Llama-3.1-8B-Instruct`)
- Backend: `vllm`, max context length 32768, GPU memory utilization 90%
- Tool calling enabled (`--enable-auto-tool-choice`, `--tool-call-parser=llama3_json`) — required for `search_kubeflow_docs` function calls
- HF token injected from `huggingface-secret` via `secretKeyRef`

**KServe endpoint output:**
```
http://llama.docs-agent.svc.cluster.local/openai/v1/chat/completions
```
This is wired into `module.api_server.llm_endpoint` automatically when `deploy_kserve = true`.

**Why `kubernetes_manifest` instead of native resources:**
KServe's `ServingRuntime` and `InferenceService` are custom resources. The Kubernetes Terraform provider doesn't have native resource types for them — `kubernetes_manifest` handles arbitrary CRDs by passing raw HCL maps.

**Known limitation — CRD must exist at plan time:**
`kubernetes_manifest` requires the CRD to be registered in the cluster when `terraform plan` runs (for field validation). Since KServe is installed by the `kubeflow-platform` module (Phase 6), planning with `deploy_kserve=true` on a bare cluster will warn:
```
no matches for kind "ServingRuntime" in group "serving.kserve.io"
```
This is expected locally. On the real OCI cluster with KServe installed, planning succeeds cleanly.

**Test results (Docker Desktop):**

| Test | Result | Notes |
|------|--------|-------|
| `terraform validate` | ✅ Valid | |
| `plan -var="deploy_kserve=false"` | ✅ 8 resources, 0 KServe | Toggle works correctly |
| `plan -var="deploy_kserve=true"` | ✅ 9 resources planned | HF secret appears; CRD warning expected (no KServe locally) |
| `kserve_endpoint` output | ✅ Correct URL | `http://llama.docs-agent.svc.cluster.local/openai/v1/chat/completions` |

---

### Phase 6 — Kubeflow Platform Module ✅ COMPLETE (implemented, full test on OCI cluster)

**Goal:** Full `terraform apply` from bare OKE cluster to running Kubeflow + docs-agent stack.

**Files implemented:**
- `modules/kubeflow-platform/main.tf` — `null_resource` with create + destroy `local-exec` provisioners
- `scripts/install-kubeflow.sh` — clones manifests, applies components with retry, waits for core namespaces
- `scripts/uninstall-kubeflow.sh` — deletes components in reverse order
- `scripts/configure-kubectl.sh` — OCI OKE kubeconfig helper (run once before `terraform apply`)

**Provider added:** `hashicorp/null >= 3.0.0` — added to `providers.tf` for `null_resource`.

**Why `null_resource` + `local-exec`:**
Kubeflow manifests are designed for Kustomize, not Terraform. Using `kubernetes_manifest` for 200+ resources would be a maintenance nightmare and fights the official install method. The `null_resource` approach wraps the supported `kustomize build | kubectl apply` workflow while giving Terraform a hook to track install state and trigger re-installs.

**Triggers — when does Kubeflow re-install?**

| Trigger | Change that forces re-install |
|---------|------------------------------|
| `kf_version` | Branch/tag changed (e.g. `master` → `v1.9.0`) |
| `kf_components` | Component list changed (added/removed a component) |
| `kubeconfig` | Switched to a different cluster |

**Install script key details:**
- Clones `github.com/kubeflow/manifests` at `$KF_VERSION` to `/tmp/kubeflow-manifests`
- If already cloned, fetches + checks out the specified version (idempotent)
- Uses `--server-side` apply — avoids `metadata.annotations size exceeds 262144 bytes` error that large Kubeflow manifests hit with client-side apply
- Retry loop (5 attempts, 30s wait) — CRDs (cert-manager, Istio) take time to establish; later components that use those CRDs fail on attempt 1 and succeed on retry 2+
- Waits for `cert-manager`, `istio-system`, `kubeflow` deployments to be `Available` after install

**Destroy script key details:**
- Reads `$KF_COMPONENTS` from `self.triggers` (the exact list used at install time)
- Deletes in reverse order — ensures dependencies are cleaned up after dependents
- `--ignore-not-found=true` — safe to run even if some resources were already removed

**`self.triggers` pattern for destroy:**
The destroy provisioner can't call Terraform functions — it can only read `self.triggers.*`. By storing `kf_components` as a comma-joined string in triggers (not a hash), the destroy script can reconstruct the full list:
```hcl
triggers = {
  kf_components = join(",", var.kf_components)  # stored as string, not hash
}
# In destroy provisioner:
KF_COMPONENTS = self.triggers.kf_components
```

**Test:** `terraform validate` ✅ — full end-to-end test runs on OCI cluster (requires real OKE + kubectl + kustomize).

---

### Phase 7 — Documentation & Cleanup

**Goal:** Repo is ready for handoff and CI.

**Deliverables:**
- `docs/REQUIREMENTS.md` — full functional and non-functional requirements
- `README.md` — quickstart guide (prerequisites → clone → init → apply)
- `scripts/verify.sh` — post-deploy health check script
- Full destroy + re-apply cycle verified

---
