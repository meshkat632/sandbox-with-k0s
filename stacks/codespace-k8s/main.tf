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
# cert-manager + Let's Encrypt
# ClusterIssuers letsencrypt-staging and letsencrypt-prod solve HTTP-01
# challenges through ingress-nginx on port 80, so no DNS access is needed.
# =============================================================================

locals {
  charts_dir = "${path.module}/../../charts"

  # Terraform only sees chart changes through its inputs, so each local chart
  # gets a hash of its files as a value: editing any of them triggers an upgrade.
  chart_checksum = {
    for c in ["nginx-hello-world", "letsencrypt-issuers"] :
    c => sha256(join("", [for f in sort(fileset("${local.charts_dir}/${c}", "**")) : filesha256("${local.charts_dir}/${c}/${f}")]))
  }
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true

  values = [
    yamlencode({
      crds = {
        enabled = true
        keep    = true # uninstalling the release must not delete every Certificate
      }
    })
  ]

  atomic  = true
  wait    = true
  timeout = 600
}

resource "helm_release" "letsencrypt_issuers" {
  name      = "letsencrypt-issuers"
  chart     = "${local.charts_dir}/letsencrypt-issuers"
  namespace = helm_release.cert_manager.namespace

  values = [
    yamlencode({
      email            = var.letsencrypt_email
      ingressClassName = "nginx"
      chartChecksum    = local.chart_checksum["letsencrypt-issuers"]
    })
  ]

  atomic = true
  wait   = true

  # The cert-manager webhook must be up to accept ClusterIssuers
  depends_on = [helm_release.cert_manager]
}

# =============================================================================
# nginx-hello-world: the local chart in charts/ at the repo root, served over
# HTTPS at var.hello_host with a Let's Encrypt certificate.
# =============================================================================

locals {
  # sslip.io resolves <a-b-c-d>.sslip.io to a.b.c.d, so no DNS record is needed
  hello_host = coalesce(var.hello_host, "hello.${replace(local.public_host, ".", "-")}.sslip.io")
}

resource "helm_release" "nginx_hello_world" {
  name      = "nginx-hello-world"
  chart     = "${local.charts_dir}/nginx-hello-world"
  namespace = kubernetes_namespace_v1.this["apps"].metadata[0].name

  values = [
    yamlencode({
      page = {
        title   = "Hello from codespace"
        message = "Served by nginx on the codespace k0s cluster, deployed from a local Helm chart."
      }
      ingress = {
        className = "nginx"
        host      = local.hello_host
        annotations = {
          "cert-manager.io/cluster-issuer" = "letsencrypt-${var.letsencrypt_environment}"
        }
        tls = [{
          secretName = "nginx-hello-world-tls"
          hosts      = [local.hello_host]
        }]
      }
      podAnnotations = {
        "checksum/chart" = local.chart_checksum["nginx-hello-world"]
      }
    })
  ]

  atomic  = true
  wait    = true
  timeout = 300

  # The ingress-nginx admission webhook must be up before the Ingress is
  # accepted, and the issuer must exist before cert-manager can act on it
  depends_on = [helm_release.ingress_nginx, helm_release.letsencrypt_issuers]
}
