# Deployment Guide: Kubeflow on OCI (OKE)

This guide walks through deploying an OKE cluster and Kubeflow platform on Oracle Cloud Infrastructure.

## Infrastructure Overview

| Resource | Spec |
|----------|------|
| Compute | 2 × VM.Standard.E5.Flex (x86, 2 OCPU + 12 GB each) |
| Cluster | OKE Basic (free with PAYG account) |
| Boot Volume | 50 GB per node |
| Load Balancer | 1 Flexible LB (Istio ingress) |
| Object Storage | 20 GB (Terraform state backend) |

## Prerequisites

- OCI account (PAYG — required for OKE)
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) installed and configured
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- `kubectl`, `kustomize`, and `git` installed

## Phase 0: OCI Account Setup

### 1. Generate API Signing Key

```bash
mkdir -p ~/.oci
oci setup keys  # generates ~/.oci/oci_api_key.pem + public key
```

Upload the **public key** to: **OCI Console → Profile → API Keys → Add API Key**

### 2. Collect Required OCIDs

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
  --name terraform-state-kubeflow
```

Create a **Customer Secret Key** for S3-compatible access:
**OCI Console → Profile → Customer Secret Keys → Generate Secret Key**

Save the Access Key and Secret Key — you'll need them as environment variables.

## Phase 1: Configure Terraform

### 4. Create terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
```

Fill in real values (see `terraform.tfvars.example` for all fields).

### 5. Set Backend Credentials

```bash
export AWS_ACCESS_KEY_ID="<customer-secret-key-id>"
export AWS_SECRET_ACCESS_KEY="<customer-secret-key>"
```

### 6. Initialize Terraform

```bash
terraform init
```

## Phase 2: Deploy

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
# Expected: 2 x86 nodes in Ready state
```

### 9. Install Kubeflow Platform (~10-20 min)

```bash
terraform apply -target=module.kubeflow_platform
```

This installs via kustomize: cert-manager, Istio, Dex+OAuth2-proxy, Knative Serving, KServe, Pipelines, Central Dashboard, and Profiles.

The install script retries up to 8 times per component (CRDs take time to establish).

```bash
# Verify — all pods should eventually be Running
kubectl get pods -n kubeflow
kubectl get pods -n istio-system
kubectl get pods -n cert-manager
kubectl get pods -n knative-serving
```

### 10. Access the Dashboard

**Port-forward:**

```bash
kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80
# Open http://localhost:8080
```

**Via LoadBalancer (public IP):**

```bash
kubectl get svc istio-ingressgateway -n istio-system
# EXTERNAL-IP column shows the public IP
# Open http://<EXTERNAL-IP>
```

Default login: `user@example.com` / `12341234` (Dex static credentials)

## One-Shot Deploy

Once you've verified layer-by-layer, future deploys can use:

```bash
terraform apply
```

## Destroy

```bash
terraform destroy
```

The uninstall script deletes Kubeflow components in reverse order before Terraform removes the OKE cluster.

## Port-Forward Quick Reference

```bash
# Kubeflow Dashboard
kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80

# Kubeflow Pipelines UI (through dashboard or directly)
kubectl port-forward svc/ml-pipeline-ui -n kubeflow 8888:80
```

## Kubeflow Components Installed

| Component | Purpose |
|-----------|---------|
| cert-manager | TLS certificate management |
| Istio | Service mesh + ingress gateway |
| Dex + OAuth2-proxy | Authentication |
| Knative Serving | Serverless workloads (used by KServe) |
| KServe | Model serving framework |
| Kubeflow Pipelines | ML workflow orchestration |
| Central Dashboard | Web UI for all KF components |
| Profiles | Multi-tenancy / namespace management |

**Not installed** (to save resources): Notebooks, Katib, Training Operator, Tensorboard, Spark Operator, Volumes Manager.
