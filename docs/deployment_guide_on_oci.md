# Deployment Guide: Kubeflow Docs-Agent on OCI

This guide walks through deploying the full docs-agent stack on Oracle Cloud Infrastructure (OCI) using the Always Free Tier.

## Infrastructure Overview

| Resource | Spec |
|----------|------|
| Compute | 2 × ARM A1.Flex (2 OCPU + 12 GB each) |
| Cluster | OKE Basic (free with PAYG account) |
| Boot Volume | 50 GB per node |
| Load Balancer | 1 Flexible LB (10 Mbps, free) |
| Object Storage | 20 GB (Terraform state backend) |
| GPU | None (uses external Groq LLM) |

## Prerequisites

- OCI account (PAYG — required for OKE even though resources are free tier)
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) installed
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- `kubectl` installed
- A [Groq API key](https://console.groq.com) (free tier, ~30 RPM)

## Phase 0: OCI Account Setup

### 1. Generate API Signing Key

```bash
mkdir -p ~/.oci
oci setup keys  # generates ~/.oci/oci_api_key.pem + public key
```

Upload the **public key** to: **OCI Console → Profile → API Keys → Add API Key**

### 2. Collect Required OCIDs

From the OCI Console, note down:

| Value | Where to find it |
|-------|-----------------|
| `tenancy_ocid` | Tenancy Details page |
| `user_ocid` | Profile → User Settings |
| `fingerprint` | Shown after uploading the API key |
| `compartment_id` | Identity → Compartments (or use tenancy OCID for root) |
| `region` | Top-right of console (e.g. `us-ashburn-1`) |

### 3. Create Object Storage Bucket (Terraform State Backend)

```bash
oci os bucket create \
  --compartment-id <compartment_id> \
  --name terraform-state
```

Create a **Customer Secret Key** for S3-compatible access:
**OCI Console → Profile → Customer Secret Keys → Generate Secret Key**

Save the Access Key and Secret Key — you'll need them as environment variables.

## Phase 1: Configure Terraform

### 4. Create terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
```

Fill in real values:

```hcl
# OCI Authentication
tenancy_ocid     = "ocid1.tenancy.oc1..actual"
user_ocid        = "ocid1.user.oc1..actual"
fingerprint      = "xx:yy:zz:..."
private_key_path = "~/.oci/oci_api_key.pem"
region           = "us-ashburn-1"

# OKE Cluster
compartment_id      = "ocid1.compartment.oc1..actual"
cluster_name        = "docs-agent-cluster"
k8s_version         = "v1.30.1"
node_count          = 2
node_ocpus          = 2
node_memory_gb      = 12
node_boot_volume_gb = 50

# LLM
groq_api_key = "gsk_xxxxxxxxxxxxxxxxxxxx"
llm_model    = "llama-3.1-8b-instant"
llm_base_url = "https://api.groq.com/openai/v1"

# MCP Server
mcp_image = "ghcr.io/kmr-rohit/mcp-kubeflow-docs:sha-473f421"

# Istio (true for OCI with full Kubeflow)
istio_enabled = true

# ETL — leave false initially, enable after stack is up
run_etl_pipeline = false
etl_image        = "ghcr.io/kmr-rohit/etl-kubeflow-docs:v1.0.0"
```

### 5. Set Backend Credentials

```bash
export AWS_ACCESS_KEY_ID="<customer-secret-key-id>"
export AWS_SECRET_ACCESS_KEY="<customer-secret-key>"
```

### 6. Initialize Terraform

```bash
terraform init
```

## Phase 2: Deploy Infrastructure

Deploy layer by layer to catch issues early.

### 7. Create OKE Cluster (~10-15 min)

```bash
terraform apply -target=module.oke_cluster
```

### 8. Generate Kubeconfig

```bash
# Use the command from terraform output
$(terraform output -raw kubeconfig_command)

# Verify nodes are ready
kubectl get nodes
# Expected: 2 ARM nodes in Ready state
```

### 9. Install Kubeflow Platform (~5-10 min)

```bash
terraform apply -target=module.kubeflow_platform
```

This uses kustomize to install: cert-manager, Istio, Dex, Knative, KServe, Pipelines, Central Dashboard, Profiles.

The install script retries up to 5 times (CRDs take time to establish).

```bash
# Verify — all pods should eventually be Running
kubectl get pods -n kubeflow
kubectl get pods -n istio-system
kubectl get pods -n cert-manager
```

### 10. Deploy Milvus

```bash
terraform apply -target=module.milvus
```

```bash
# Verify — 3 pods: standalone, etcd, minio
kubectl get pods -n docs-agent
```

### 11. Deploy RBAC + MCP Server

```bash
terraform apply -target=module.rbac -target=module.mcp_server
```

```bash
# Verify MCP server is running
kubectl get pods -n docs-agent -l app=mcp-kubeflow-docs
```

### 12. Deploy kagent (Two-Phase Apply)

kagent uses custom CRDs that must be registered before instances can be created.

```bash
# Phase 1: Install Helm charts (registers CRDs)
terraform apply -target=module.kagent

# Phase 2: Create CRD instances (re-run if Phase 1 errored on CRDs)
terraform apply -target=module.kagent
```

```bash
# Verify
kubectl get pods -n docs-agent -l app.kubernetes.io/name=kagent
```

## Phase 3: Index Documentation

### 13. Run ETL Pipeline

Edit `terraform.tfvars`:

```hcl
run_etl_pipeline = true
# Optional: provide a GitHub token for higher API rate limits
# github_token = "ghp_xxxxxxxxxxxxxxxxxxxx"
```

```bash
terraform apply -target=module.etl_pipeline
```

This runs a K8s Job that:
1. Crawls `kubeflow/website` docs from GitHub (~500+ files)
2. Chunks and embeds with `sentence-transformers/all-mpnet-base-v2` (768-dim)
3. Stores vectors in Milvus collection `kubeflow_docs_docs_rag`

The apply blocks until the Job completes (~5-15 min depending on doc count).

```bash
# Watch progress
kubectl logs -n docs-agent -l app=etl-pipeline -f
```

## Phase 4: Verify

### 14. Test the Stack

**Option A: kagent UI**

```bash
kubectl -n docs-agent port-forward service/kagent-ui 8080:8080
# Open http://localhost:8080
# Ask: "How do I install Kubeflow?"
```

**Option B: MCP Server directly**

```bash
kubectl -n docs-agent port-forward svc/mcp-kubeflow-docs 8000:8000

# Initialize MCP session
curl -s -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

**Option C: Verify Milvus data**

```bash
kubectl -n docs-agent port-forward svc/my-release-milvus 19530:19530

python3 -c "
from pymilvus import connections, Collection
connections.connect('default', host='localhost', port='19530', user='root', password='Milvus')
col = Collection('kubeflow_docs_docs_rag')
col.load()
print(f'Collection has {col.num_entities} vectors')
connections.disconnect('default')
"
```

## One-Shot Deploy (After Initial Setup)

Once you've verified layer-by-layer, future deploys can be done in one command:

```bash
terraform apply
```

## Re-indexing Docs

K8s Jobs are immutable. To re-run the ETL pipeline:

```bash
terraform taint 'module.etl_pipeline[0].kubernetes_job_v1.etl_pipeline'
terraform apply -target=module.etl_pipeline
```

Or toggle off and on:

```bash
# In terraform.tfvars: run_etl_pipeline = false
terraform apply -target=module.etl_pipeline
# In terraform.tfvars: run_etl_pipeline = true
terraform apply -target=module.etl_pipeline
```

## Enabling KServe (Optional — GPU Required)

If you have access to GPU nodes (e.g. on `cncfkubeflow` cluster):

```hcl
deploy_kserve     = true
huggingface_token = "hf_xxxxxxxxxxxxxxxxxxxx"
kserve_model_id   = "RedHatAI/Llama-3.1-8B-Instruct"
```

```bash
terraform apply -target=module.kserve_llm
```

## Troubleshooting

### Pod not starting

```bash
kubectl describe pod <pod-name> -n docs-agent
kubectl get events -n docs-agent --sort-by='.lastTimestamp'
```

### ARM image compatibility (`exec format error`)

Some images may not have ARM builds. Check:

```bash
kubectl logs <pod-name> -n docs-agent
```

If you see `exec format error`, that image needs an ARM-compatible alternative.

### Resource pressure (OOMKilled)

```bash
kubectl top nodes
kubectl top pods -n docs-agent
```

24 GB is tight. If pods get OOMKilled, consider reducing KF components in `kf_components` variable.

### OCI ARM capacity issues

ARM A1 instances sometimes hit "Out of host capacity" errors. Try:
- A different availability domain
- A different region
- Retry later (capacity fluctuates)

### Kubeflow install failures

The kustomize install retries 5 times with 30s waits. If it still fails:

```bash
# Check which component failed
kubectl get pods -A | grep -v Running

# Re-run just the kubeflow module
terraform taint module.kubeflow_platform.null_resource.kubeflow_install
terraform apply -target=module.kubeflow_platform
```

### Full reset

```bash
terraform destroy
terraform apply
```

## Docker Images Used

| Component | Image | Arch |
|-----------|-------|------|
| MCP Server | `ghcr.io/kmr-rohit/mcp-kubeflow-docs:sha-473f421` | amd64 + arm64 |
| ETL Pipeline | `ghcr.io/kmr-rohit/etl-kubeflow-docs:v1.0.0` | amd64 + arm64 |
| kagent App | `cr.kagent.dev/kagent-dev/kagent/app:0.7.20` | amd64 + arm64 |
| Milvus | `milvusdb/milvus:v2.4.9` (via Helm chart 4.2.7) | amd64 + arm64 |

## Port-Forward Quick Reference

```bash
# Kubeflow Dashboard
kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80

# kagent UI
kubectl -n docs-agent port-forward service/kagent-ui 8080:8080

# Milvus
kubectl -n docs-agent port-forward svc/my-release-milvus 19530:19530

# MCP Server
kubectl -n docs-agent port-forward svc/mcp-kubeflow-docs 8000:8000
```
