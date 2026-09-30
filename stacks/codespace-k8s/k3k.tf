# =============================================================================
# k3k: controller + CRDs (clusters.k3k.io, ...) for virtual clusters.
# Terraform owns only the platform; the virtual clusters themselves are
# created with k3kcli (stacks/k3k/create-cluster.sh) and stay unknown here.
# Keep the chart version in step with the k3kcli release in use.
# =============================================================================

variable "k3k_chart_version" {
  description = "k3k Helm chart version (matches the k3kcli release, e.g. 1.2.0)"
  type        = string
  default     = "1.2.0"
}

# The release was first installed by hand (helm install k3k k3k/k3k -n k3k-system);
# this adopts it into state instead of installing a second one. Harmless once
# imported, can be removed after the first successful apply.
import {
  to = helm_release.k3k
  id = "k3k-system/k3k"
}

resource "helm_release" "k3k" {
  name             = "k3k"
  repository       = "https://rancher.github.io/k3k"
  chart            = "k3k"
  version          = var.k3k_chart_version
  namespace        = "k3k-system"
  create_namespace = true

  atomic  = true
  wait    = true
  timeout = 600

  # Uninstalling the chart removes its CRDs, and with them every virtual
  # cluster of every customer. Destroying it has to be a deliberate edit.
  lifecycle {
    prevent_destroy = true
  }
}