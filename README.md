# Kubeflow Docs-Agent: Terraform Infrastructure

Terraform configuration to deploy the **Kubeflow Documentation AI Assistant (docs-agent)** on **Oracle Cloud Infrastructure (OCI)**. The docs-agent is a RAG-powered chatbot that provides semantic search and contextual answers across Kubeflow documentation.

**Parent project:** [KEP-867 — Kubeflow Documentation AI Assistant](https://github.com/kubeflow/community/issues/867)

## Architecture

```
┌──────────────────────────────────────────────────┐
│  kagent UI (port 8080)                           │
│  Agent CRD → Groq LLM (ModelConfig)             │
│       │ [Tool: search_kubeflow_docs]             │
│       ▼                                          │
│  MCP Server (FastMCP, port 8000/mcp)             │
│       ▼                                          │
│  Milvus Vector DB (standalone, port 19530)       │
├──────────────────────────────────────────────────┤
│  Kubeflow Platform (Kustomize)                   │
│  Istio, Pipelines, KServe, cert-manager, Dex     │
├──────────────────────────────────────────────────┤
│  OKE Cluster — 2 ARM nodes × (2 OCPU + 12 GB)   │
└──────────────────────────────────────────────────┘
```

**Hybrid approach:** Kubeflow platform is installed via Kustomize (the officially supported method). The docs-agent stack (Milvus, MCP server, kagent) uses native Terraform resources for full state tracking.

## Prerequisites

- **OCI account** — PAYG (pay-as-you-go) required for OKE; compute stays within Always Free Tier
- **Terraform** >= 1.5.0
- **OCI CLI** — [install guide](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm)
- **kubectl** — matching your cluster's Kubernetes version
- **kustomize** — for Kubeflow platform install
- **Groq API key** — free at [console.groq.com](https://console.groq.com) (used for LLM inference)

## OCI Setup

### 1. Create a compartment

In the OCI Console, go to **Identity → Compartments** and create one (or use the root compartment, which equals your `tenancy_ocid`).

### 2. Generate an API signing key

```bash
mkdir -p ~/.oci
oci setup config  # Interactive — generates key pair + config file
```

This produces `~/.oci/oci_api_key.pem` and `~/.oci/config`. Note the `tenancy`, `user`, `fingerprint`, and `region` values.

### 3. Create a state backend bucket

The Terraform backend uses OCI Object Storage via the S3-compatible API.

```bash
oci os bucket create \
  --compartment-id <compartment_ocid> \
  --name terraform-state-docs-agent
```

### 4. Create Customer Secret Keys (for S3-compat access)

In the OCI Console: **Identity → Users → your user → Customer Secret Keys → Generate Secret Key**.

Save both values — you'll need them as environment variables:

```bash
export AWS_ACCESS_KEY_ID="<customer_secret_key_id>"
export AWS_SECRET_ACCESS_KEY="<customer_secret_key_value>"
```

### 5. Update the backend endpoint

Edit `backend.tf` and replace the `endpoint` with your namespace and region:

```
https://<namespace>.compat.objectstorage.<region>.oraclecloud.com
```

Find your namespace in the OCI Console under **Tenancy Details**.

## Configure

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values. The required variables are:

| Variable | Description |
|----------|-------------|
| `tenancy_ocid` | OCI tenancy OCID |
| `user_ocid` | OCI user OCID |
| `fingerprint` | API key fingerprint |
| `private_key_path` | Path to `~/.oci/oci_api_key.pem` |
| `region` | OCI region (e.g. `us-ashburn-1`) |
| `compartment_id` | Compartment OCID |
| `groq_api_key` | Groq API key |
| `mcp_image` | MCP server Docker image (e.g. `ghcr.io/kmr-rohit/mcp-kubeflow-docs:sha-473f421`) |

All other variables have sensible defaults. See `terraform.tfvars.example` for the full list.

## Deploy

### Initialize

```bash
terraform init
```

### Apply (two-phase)

The kagent module installs CRDs via Helm charts first, then creates CRD instances (Agent, ModelConfig, RemoteMCPServer). This requires a two-phase apply:

```bash
# Phase 1: Infrastructure + Helm charts (registers CRDs)
terraform apply

# Phase 2: CRD instances (Agent, ModelConfig, RemoteMCPServer)
terraform apply
```

The first apply will show errors for the kagent CRD resources — this is expected. The second apply succeeds because the CRDs are now registered.

### What gets created

| Module | Resources |
|--------|-----------|
| `oke_cluster` | VCN, subnets, security lists, OKE cluster, ARM node pool |
| `kubeflow_platform` | Kubeflow components via Kustomize (Istio, Pipelines, KServe, etc.) |
| `milvus` | Namespace `docs-agent`, Milvus Helm release (standalone mode) |
| `rbac` | Role + RoleBinding (KFP service account → Milvus access) |
| `mcp_server` | ConfigMap, Secret, Deployment, Service |
| `kagent` | kagent Helm charts, Agent CRD, ModelConfig, RemoteMCPServer |
| `kserve_llm` | *(optional)* ServingRuntime + InferenceService for on-cluster LLM |

## Post-Deploy

### Generate kubeconfig

```bash
# The exact command is output by Terraform:
terraform output -raw kubeconfig_command | bash
```

### Verify

```bash
# Check nodes
kubectl get nodes

# Check docs-agent pods (expect ~9 pods)
kubectl get pods -n docs-agent

# Check kagent Agent status
kubectl get agents -n docs-agent
```

### Access the kagent UI

```bash
# Get the port-forward command from Terraform output:
terraform output -raw kagent_ui_command

# Or manually:
kubectl port-forward svc/kagent -n docs-agent 8080:80
```

Then open http://localhost:8080 and send a query to the docs-agent.

### Other useful port-forwards

```bash
# Kubeflow Dashboard
kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80

# Milvus (for debugging)
kubectl port-forward svc/my-release-milvus -n docs-agent 19530:19530

# MCP Server
kubectl port-forward svc/mcp-server -n docs-agent 8000:8000
```

> **Note:** The Milvus collection `kubeflow_docs_docs_rag` will be empty until the ETL pipeline runs. The LLM will gracefully fall back to answering without RAG context.

## KServe (Optional — GPU Required)

To run the LLM on-cluster instead of using Groq, enable KServe:

```hcl
# In terraform.tfvars:
deploy_kserve     = true
huggingface_token = "hf_xxxxxxxxxxxxxxxxxxxx"
```

This deploys a vLLM-backed InferenceService running Llama 3.1-8B. Requires a node with an NVIDIA GPU — not available on the OCI free tier.

## Local Testing (Docker Desktop)

You can test the docs-agent stack locally without an OCI account.

### 1. Override the backend

Create `backend_override.tf` (gitignored via `*_override.tf`):

```hcl
terraform {
  backend "local" {}
}
```

### 2. Comment out OCI-dependent modules

In `main.tf`, comment out `module "oke_cluster"` and `module "kserve_llm"`, and their corresponding entries in `outputs.tf`. Remove `depends_on` references to these modules.

### 3. Create a dummy OCI key

```bash
openssl genrsa -out /tmp/dummy_oci_key.pem 2048
```

### 4. Apply

```bash
terraform init -reconfigure

# Phase 1: Helm charts
terraform apply \
  -var="compartment_id=ocid1.compartment.oc1..dummy" \
  -var="groq_api_key=gsk_your_key" \
  -var="mcp_image=ghcr.io/kmr-rohit/mcp-kubeflow-docs:sha-473f421" \
  -var="private_key_path=/tmp/dummy_oci_key.pem" \
  -var="istio_enabled=false"

# Phase 2: CRD instances
terraform apply \
  -var="compartment_id=ocid1.compartment.oc1..dummy" \
  -var="groq_api_key=gsk_your_key" \
  -var="mcp_image=ghcr.io/kmr-rohit/mcp-kubeflow-docs:sha-473f421" \
  -var="private_key_path=/tmp/dummy_oci_key.pem" \
  -var="istio_enabled=false"
```

Set `istio_enabled = false` to skip Istio AuthorizationPolicies (no Istio in Docker Desktop).

## Teardown

```bash
terraform destroy
```

## Troubleshooting

### ARM image compatibility

OCI free tier uses ARM (aarch64) processors. If a pod fails with `exec format error`, that image doesn't have an ARM build. Check for a multi-arch alternative.

### OCI "Out of host capacity"

ARM A1 instances can hit capacity limits in some regions. Try a different availability domain or wait and retry.

### CRD errors on first apply

```
Error: the server doesn't have a resource type "agents"
```

This is expected on the first `terraform apply`. The kagent Helm chart registers the CRDs, but Terraform tries to create CRD instances in the same run before they're available. Run `terraform apply` again.

### kagent UI returns 502

The kagent nginx frontend expects the controller at `localhost:8083` inside the pod. If port-forwarding the `kagent` service shows 502, port-forward the controller directly:

```bash
kubectl port-forward deployment/kagent-controller -n docs-agent 8083:8083
```

### Milvus pod stuck in Pending

Check if persistence is accidentally enabled — Docker Desktop / OCI free tier may not have a StorageClass that supports dynamic provisioning. The default Helm values in this config disable all persistence.

### Kubeflow install hangs or fails

The `install-kubeflow.sh` script retries up to 5 times with 30-second waits for CRDs to establish. If it still fails, run the script manually:

```bash
bash scripts/install-kubeflow.sh --kubeconfig ~/.kube/config --version master
```

## Module Structure

```
├── main.tf                    # Root orchestration
├── providers.tf               # OCI, Kubernetes, Helm providers
├── variables.tf               # All input variables
├── outputs.tf                 # Cluster endpoints, UI commands
├── backend.tf                 # OCI Object Storage S3-compat backend
├── terraform.tfvars.example   # Example values (committed)
├── modules/
│   ├── oke-cluster/           # OCI VCN + OKE + ARM node pool
│   ├── kubeflow-platform/     # Kustomize install wrapper
│   ├── milvus/                # Helm standalone + Istio policies
│   ├── rbac/                  # KFP SA → Milvus access
│   ├── mcp-server/            # FastMCP tool server
│   ├── kagent/                # kagent Helm + Agent/ModelConfig CRDs
│   └── kserve-llm/            # GPU-gated KServe InferenceService
├── scripts/
│   ├── install-kubeflow.sh    # Kustomize install wrapper
│   ├── uninstall-kubeflow.sh  # Reverse-order kustomize delete
│   └── configure-kubectl.sh   # OKE kubeconfig helper
└── docs/
    ├── PLAN.md                # Implementation plan
    └── REQUIREMENTS.md        # Requirements document
```

## Links

- [KEP-867 — Kubeflow Documentation AI Assistant](https://github.com/kubeflow/community/issues/867)
- [kubeflow/manifests](https://github.com/kubeflow/manifests) — Kubeflow installation source
- [kagent](https://github.com/kagent-dev/kagent) — Agent orchestration framework
- [Milvus Helm](https://milvus.io/docs/install_standalone-helm.md) — Vector DB installation
- [OCI Terraform provider](https://registry.terraform.io/providers/oracle/oci/latest/docs)
- [OKE documentation](https://docs.oracle.com/en-us/iaas/Content/ContEng/home.htm)
