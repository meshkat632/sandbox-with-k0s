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

  # The API server address is the instance's Elastic IP, which also serves the ingress
  public_host = nonsensitive(regex("^https://([^:/]+)", local.kubeconfig.clusters[0].cluster.server)[0])
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

# =============================================================================
# ingress-nginx
# Single-node cluster without a cloud load balancer, so the controller binds
# ports 80/443 of the instance itself (hostPort); the codespace stack's
# security group opens them to web_allowed_cidrs. A DaemonSet, because a
# Deployment's rolling update would wait forever for the ports to free up.
# =============================================================================

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version
  namespace        = "ingress-nginx"
  create_namespace = true

  values = [
    yamlencode({
      controller = {
        kind = "DaemonSet"
        hostPort = {
          enabled = true
          ports   = { http = 80, https = 443 }
        }
        ingressClassResource = {
          default = true
        }
        service = {
          type = "ClusterIP"
        }
      }
    })
  ]

  atomic  = true # roll back a failed install or upgrade
  wait    = true
  timeout = 600
}

# =============================================================================
# nginx-hello-world: the local chart in charts/ at the repo root, served at /
# on the ingress NodePorts.
# =============================================================================

locals {
  hello_chart = "${path.module}/../../charts/nginx-hello-world"
}

resource "helm_release" "nginx_hello_world" {
  name      = "nginx-hello-world"
  chart     = local.hello_chart
  namespace = kubernetes_namespace_v1.this["apps"].metadata[0].name

  values = [
    yamlencode({
      page = {
        title   = "Hello from codespace"
        message = "Served by nginx on the codespace k0s cluster, deployed from a local Helm chart."
      }
      ingress = {
        className = "nginx"
      }
      podAnnotations = {
        # Terraform only sees chart changes through its inputs, so feed it a
        # hash of the chart files: editing any of them triggers an upgrade.
        "checksum/chart" = sha256(join("", [for f in sort(fileset(local.hello_chart, "**")) : filesha256("${local.hello_chart}/${f}")]))
      }
    })
  ]

  atomic  = true
  wait    = true
  timeout = 300

  # The ingress-nginx admission webhook must be up before the Ingress is accepted
  depends_on = [helm_release.ingress_nginx]
}
