# Troubleshooting: Kubeflow on OCI (OKE)

Common issues encountered during deployment and their solutions.

---

## OKE Node Pool Issues

### Nodes stuck in TERMINATED or not coming up

**Symptom:** Node pool shows nodes in `TERMINATED` state or nodes never become `Ready`.

**Root cause:** Missing security list rules. OKE with Flannel CNI requires broad TCP access between the API endpoint subnet and the worker node subnet. Without these rules, the kubelet can't register with the API server.

**Required security list rules:**

| Direction | Subnet | Protocol | Ports | Purpose |
|-----------|--------|----------|-------|---------|
| API → Workers | Egress | ALL TCP | All | Flannel CNI communication |
| API → Workers | Egress | ICMP 3,4 | — | Path MTU discovery |
| Workers → API | Ingress | TCP | 6443 | Kubernetes API |
| Workers → API | Ingress | TCP | 12250 | OKE control plane |
| Workers → API | Ingress | ICMP 3,4 | — | Path MTU discovery |
| API → OCI Services | Egress | TCP | 443 | Oracle Services Network (critical!) |

The **TCP/443 egress to Oracle Services Network** rule is the most commonly missed. Without it, nodes can't reach OCI internal services (container registry, metadata service) and fail to boot.

**Reference:** [OCI Container Engine Networking](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengnetworkconfig.htm)

---

## CRI-O Short-Name Image Rejection

**Symptom:** Pods fail to start with `ImagePullBackOff`. Describing the pod shows:
```
Failed to pull image "kserve/kserve-controller:v0.16.0": rpc error: short-name resolution
```

**Root cause:** OKE uses CRI-O as the container runtime, which enforces fully-qualified image names. Images like `kserve/foo:tag` must include the registry prefix `docker.io/kserve/foo:tag`.

**Fix:** The install script (`scripts/install-kubeflow.sh`) includes a `sed` pipeline that automatically prefixes `docker.io/` to known short-name images:

```bash
sed -E '
    s|image: kserve/|image: docker.io/kserve/|g;
    s|image: mysql:|image: docker.io/mysql:|g;
    s|image: chrislusf/|image: docker.io/chrislusf/|g;
'
```

Additionally, `fix_short_name_images()` runs after KServe installation to patch any remaining unqualified images in running deployments.

If you encounter a new short-name image not covered by the sed rules, add a new substitution line.

---

## MySQL PVC Not Found (Kubeflow Pipelines)

**Symptom:** `mysql` pod stuck in `Pending`:
```
pod has unbound immediate PersistentVolumeClaims
```

**Root cause:** Kubeflow Pipelines expects a PVC named `mysql-pv-claim` but the manifests don't always create it. On OKE, the default StorageClass is `oci-bv` (OCI Block Volume).

**Fix:** The install script includes `ensure_mysql_pvc()` which creates the PVC automatically before installing Pipelines components:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pv-claim
  namespace: kubeflow
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: oci-bv
  resources:
    requests:
      storage: 20Gi
```

If you need to create it manually:
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pv-claim
  namespace: kubeflow
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: oci-bv
  resources:
    requests:
      storage: 20Gi
EOF
```

---

## MySQL 8 Crash: `--mysql-native-password=ON`

**Symptom:** MySQL pod in `CrashLoopBackOff` with logs:
```
unknown option '--mysql-native-password=ON'
```

**Root cause:** Recent MySQL 8.x versions deprecated the `--mysql-native-password=ON` flag. Kubeflow manifests may still include it.

**Fix:** The install script's sed pipeline strips this flag:
```bash
/mysql-native-password=ON/d
```

---

## Knative Webhook Server-Side Apply Conflicts

**Symptom:** `kubectl apply` fails with:
```
Apply failed with 1 conflict: conflict with "webhook" using networking.internal.knative.dev/v1alpha1
```

**Root cause:** Knative's webhook controller manages its own webhook configuration rules. Server-side apply detects a field ownership conflict.

**Fix:** Use `--force-conflicts` with `--server-side` apply. The install script already does this:
```bash
kubectl apply --server-side --force-conflicts --kubeconfig="$KUBECONFIG" -f -
```

---

## KServe Webhook Failures (EOF)

**Symptom:** Components that depend on KServe CRDs fail with:
```
failed calling webhook "inferenceservice.kserve-webhook-server.validator"
```

**Root cause:** KServe webhook server isn't ready yet. This can happen because:
1. The KServe controller image had a short-name issue (see CRI-O section above)
2. The controller deployment is still rolling out

**Fix:** The install script includes `wait_for_kserve_webhook()` which waits up to 3 minutes for the KServe controller to become available before proceeding with subsequent components. The retry loop also detects webhook failures and waits for deployments in the kubeflow namespace.

---

## Dex: "Failed to retrieve connector list"

**Symptom:** Clicking "Sign in with Dex" on the Kubeflow dashboard shows an Internal Server Error.

**Root cause:** Transient 429/TooManyRequests from the Kubernetes API during Dex initialization. Dex's storage is backed by K8s CRDs, and during cluster setup the API server may throttle requests.

**Fix:** Restart the Dex deployment:
```bash
kubectl rollout restart deployment dex -n auth
```

Wait ~30 seconds and try again. This is a one-time issue during initial setup.

---

## metadata-grpc-server CrashLoopBackOff

**Symptom:** `metadata-grpc-deployment` pod is in CrashLoopBackOff.

**Root cause:** The metadata gRPC server starts before MySQL is available and can't establish a database connection.

**Fix:** Wait for MySQL to become Ready, then delete the crashing pod:
```bash
# Wait for MySQL
kubectl wait --for=condition=Ready pod -l app=mysql -n kubeflow --timeout=120s

# Delete the crashing pod (the Deployment will recreate it)
kubectl delete pod -l component=metadata-grpc-server -n kubeflow
```

---

## Kubeconfig Tilde Expansion

**Symptom:** `local-exec` provisioner fails with:
```
stat ~/.kube/config: no such file or directory
```

**Root cause:** Terraform's `local-exec` provisioner doesn't perform shell tilde expansion on environment variables.

**Fix:** Already handled in the kubeflow-platform module using `pathexpand()`:
```hcl
locals {
  kubeconfig = pathexpand(var.kubeconfig_path)
}
```

---

## Re-running Kubeflow Installation

If the installation fails partway through:

```bash
# Taint to force re-run
terraform taint module.kubeflow_platform.null_resource.kubeflow_install
terraform apply -target=module.kubeflow_platform
```

The install script is idempotent — it uses `kubectl apply` which is safe to re-run.

---

## Checking Component Status

```bash
# All pods across namespaces
kubectl get pods -A | grep -v Running

# Events for a specific namespace
kubectl get events -n kubeflow --sort-by='.lastTimestamp' | tail -20

# Resource usage
kubectl top nodes
kubectl top pods -n kubeflow --sort-by=memory

# Describe a problematic pod
kubectl describe pod <pod-name> -n kubeflow
```

---

## Exposing Kubeflow Dashboard via LoadBalancer

The Istio ingress gateway creates an OCI Load Balancer automatically:

```bash
kubectl get svc istio-ingressgateway -n istio-system
```

The `EXTERNAL-IP` column shows the public IP. Access via `http://<EXTERNAL-IP>`.

If the external IP stays `<pending>`, check:
1. The service subnet has correct security list (ingress TCP 80/443 from 0.0.0.0/0)
2. The OCI account has available Load Balancer quota
3. Events: `kubectl describe svc istio-ingressgateway -n istio-system`
