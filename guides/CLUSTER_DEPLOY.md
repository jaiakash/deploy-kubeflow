# Guide: Cluster Deployment

Instructions for configuring and deploying the OKE cluster.

## 1. Configure Terraform

```bash
cp terraform.tfvars.example terraform.tfvars
```

Fill in real values in `terraform.tfvars`. Refer to [OCI Authentication](OCI_AUTH.md) if you lack OCIDs or keys.

## 2. Set Backend Credentials

```bash
export AWS_ACCESS_KEY_ID="<customer-secret-key-id>"
export AWS_SECRET_ACCESS_KEY="<customer-secret-key>"
```

## 3. Initialize & Deploy Cluster (~10-15 min)

```bash
terraform init
terraform apply -target=module.oke_cluster
```

## 4. Generate Kubeconfig

```bash
# Use the command from terraform output
$(terraform output -raw kubeconfig_command)

# Verify nodes are ready
kubectl get nodes
```

---
**Next Step**: [Install Kubeflow Platform](KUBEFLOW_INSTALL.md)
