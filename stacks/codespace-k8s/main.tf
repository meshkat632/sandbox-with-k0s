# =============================================================================
# Cluster access
# The codespace stack's instance writes its admin kubeconfig to Secrets
# Manager once k0s is up. Until then the secret holds a placeholder, so this
# stack can only be applied after the cluster has finished booting.
# =============================================================================

data "aws_secretsmanager_secret_version" "kubeconfig" {
  secret_id = var.kubeconfig_secret_name

  lifecycle {
    postcondition {
      condition     = can(yamldecode(self.secret_string).clusters[0].cluster.server)
      error_message = "Secret ${var.kubeconfig_secret_name} holds no kubeconfig yet. Apply the codespace stack and wait for the instance to publish it (make kubeconfig in stacks/codespace succeeds once it has)."
    }
  }
}

locals {
  kubeconfig = yamldecode(data.aws_secretsmanager_secret_version.kubeconfig.secret_string)
}

# =============================================================================
# Namespaces
# =============================================================================

resource "kubernetes_namespace_v1" "this" {
  for_each = var.namespaces

  metadata {
    name = each.value

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}
