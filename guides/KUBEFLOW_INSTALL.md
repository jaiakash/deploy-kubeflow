# Guide: Kubeflow Platform Installation

Instructions for installing the Kubeflow platform on your OKE cluster.

## 1. Install Kubeflow (~10-20 min)

```bash
terraform apply -target=module.kubeflow_platform
```

This installs: cert-manager, Istio, Dex+OAuth2-proxy, KServe, Pipelines, and the Dashboard.

## 2. Verify Installation

```bash
# All pods should eventually be Running
kubectl get pods -A
```

## 3. Access the Dashboard

**Port-forward Quick Access:**

```bash
kubectl port-forward svc/istio-ingressgateway -n istio-system 8080:80
# Open http://localhost:8080
```

**Via LoadBalancer (Public IP):**

```bash
kubectl get svc istio-ingressgateway -n istio-system
# EXTERNAL-IP column shows the public IP
```

Default login: `user@example.com` / `12341234`

---
**Need help?** Check the [Troubleshooting Guide](TROUBLESHOOTING.md)
