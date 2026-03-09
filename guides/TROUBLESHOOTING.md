# Troubleshooting: Kubeflow on OCI

Quick solutions for common deployment issues.

---

## 🏗 Cluster & Networking

### Nodes stuck in TERMINATED / not joining
**Symptom:** Nodes never become `Ready` or stay `TERMINATED`.
**Fix:** Ensure Security List rules for the Worker subnet include:
- **Ingress**: TCP/6443, TCP/12250 (from API subnet), ALL TCP (within VCN).
- **Egress**: TCP/443 to **Oracle Services Network** (Critical for Registry/Metadata).

### Kubeconfig Errors
**Symptom:** `stat ~/.kube/config: no such file or directory`.
**Fix:** Ensure you run `$(terraform output -raw kubeconfig_command)` after cluster creation.

---

## 📦 Image & Runtime

### ImagePullBackOff (Short-name resolution)
**Symptom:** `rpc error: short-name resolution`. OKE/CRI-O requires fully-qualified names.
**Fix:** Prefix images with `docker.io/` (e.g., `image: kserve/kserve...` → `image: docker.io/kserve/kserve...`). The install script patches most of these automatically.

### Webhook Conflicts
**Symptom:** `Apply failed with 1 conflict: conflict with "webhook"`.
**Fix:** Use `--force-conflicts` with server-side apply.

---

## 🗄 Database (MySQL)

### MySQL pod stuck in Pending
**Symptom:** `unbound immediate PersistentVolumeClaims`.
**Fix:** Create a PVC named `mysql-pv-claim` in namespace `kubeflow` using `storageClassName: oci-bv`.

### MySQL CrashLoop (native-password)
**Symptom:** Logs show `unknown option '--mysql-native-password=ON'`.
**Fix:** Remove the flag from the Deployment manifest; MySQL 8+ has deprecated it.

### metadata-grpc-server CrashLoop
**Symptom:** Pod crashes repeatedly.
**Fix:** Wait for MySQL to be `Ready`, then delete the crashing pod to force a restart.

---

## 🔐 Auth (Dex)

### "Failed to retrieve connector list"
**Symptom:** Login shows Internal Server Error.
**Fix:** Restart Dex: `kubectl rollout restart deployment dex -n auth`.

---

## 🛠 Useful Commands

```bash
# Check non-running pods
kubectl get pods -A | grep -v Running

# Force re-run install
terraform taint module.kubeflow_platform.null_resource.kubeflow_install
terraform apply -target=module.kubeflow_platform
```
