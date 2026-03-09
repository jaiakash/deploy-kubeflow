# Guide: OCI Authentication & Setup

Step-by-step instructions to configure your OCI account for Kubeflow deployment.

## 1. Generate API Signing Key

```bash
mkdir -p ~/.oci
oci setup keys  # generates ~/.oci/oci_api_key.pem + public key
```

Upload the **public key** to: **OCI Console → Profile → API Keys → Add API Key**

## 2. Collect Required OCIDs

| Value | Where to find it |
| --- | --- |
| `tenancy_ocid` | Tenancy Details page |
| `user_ocid` | Profile → User Settings |
| `fingerprint` | Shown after uploading the API key |
| `compartment_id` | Identity → Compartments (or use tenancy OCID for root) |
| `region` | Top-right of console (e.g. `us-ashburn-1`) |

## 3. Create Object Storage Bucket (Terraform State Backend)

```bash
oci os bucket create \
  --compartment-id <compartment_id> \
  --name terraform-state-kubeflow
```

Create a **Customer Secret Key** for S3-compatible access:
**OCI Console → Profile → Customer Secret Keys → Generate Secret Key**

Save the Access Key and Secret Key for use as environment variables.

---
**Next Step**: [Cluster Deployment](CLUSTER_DEPLOY.md)
