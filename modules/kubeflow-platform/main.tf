locals {
  # Comma-joined string so the destroy provisioner can read it back
  # via self.triggers — Terraform functions aren't available in destroy context.
  components_str = join(",", var.kf_components)
  # Expand ~ to absolute path — local-exec doesn't do shell tilde expansion.
  kubeconfig = pathexpand(var.kubeconfig_path)
}

# null_resource wrapping the kustomize-based Kubeflow install.
# Triggers force re-install when the KF version or component list changes.
# All other modules depend on this completing before they run.
resource "null_resource" "kubeflow_install" {
  triggers = {
    kf_version    = var.kf_version
    kf_components = local.components_str
    kubeconfig    = local.kubeconfig
  }

  provisioner "local-exec" {
    command = "${path.module}/../../scripts/install-kubeflow.sh"
    environment = {
      KUBECONFIG    = local.kubeconfig
      KF_VERSION    = var.kf_version
      KF_COMPONENTS = local.components_str
    }
  }

  # Destroy provisioner runs kustomize delete in reverse component order.
  # Uses self.triggers so the correct version/components are always used,
  # even if variables have changed since the last apply.
  provisioner "local-exec" {
    when    = destroy
    command = "${path.module}/../../scripts/uninstall-kubeflow.sh"
    environment = {
      KUBECONFIG    = self.triggers.kubeconfig
      KF_VERSION    = self.triggers.kf_version
      KF_COMPONENTS = self.triggers.kf_components
    }
  }
}
