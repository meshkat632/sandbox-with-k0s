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

  # The API server address is the instance's Elastic IP, which also serves the Gateway
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
# Gateway API
# The standard-channel CRDs, applied object by object from the pinned release
# bundle. Controllers (Traefik, cert-manager) need them before they start.
# =============================================================================

data "http" "gateway_api" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Could not download Gateway API ${var.gateway_api_version} (HTTP ${self.status_code})."
    }
  }
}

locals {
  # Only what is ours to declare: the bundle also carries status stanzas and
  # null creationTimestamps, which kubernetes_manifest would fight over
  gateway_api_manifests = {
    for m in provider::kubernetes::manifest_decode_multi(data.http.gateway_api.response_body) :
    "${m.kind}/${m.metadata.name}" => {
      apiVersion = m.apiVersion
      kind       = m.kind
      metadata   = { for k, v in m.metadata : k => v if k != "creationTimestamp" }
      spec       = m.spec
    }
  }
}

resource "kubernetes_manifest" "gateway_api" {
  for_each = local.gateway_api_manifests

  manifest = each.value
}

# =============================================================================
# Traefik: the Gateway API controller (GatewayClass "traefik")
# Single-node cluster without a cloud load balancer, so Traefik binds ports
# 80/443 of the instance itself (hostPort); the codespace stack's security
# group opens them to web_allowed_cidrs. A DaemonSet, because a Deployment's
# rolling update would wait forever for the ports to free up.
# =============================================================================

resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version
  namespace        = "traefik"
  create_namespace = true

  values = [
    yamlencode({
      deployment = {
        kind = "DaemonSet"
      }
      # Replace the pod in place: a surge pod could never bind the host ports
      # the old one still holds (the chart defaults to maxSurge 1)
      updateStrategy = {
        type          = "RollingUpdate"
        rollingUpdate = { maxUnavailable = 1, maxSurge = 0 }
      }
      # Entry points listen on 8000/8443 in the pod (the Gateway's listener
      # ports) and on 80/443 of the node
      ports = {
        web       = { hostPort = 80 }
        websecure = { hostPort = 443 }
      }
      # No cloud load balancer: a LoadBalancer Service (the chart default)
      # stays <pending> and helm's wait never finishes. The chart reads the
      # type from service.spec.type, not service.type.
      service = {
        spec = { type = "ClusterIP" }
      }
      providers = {
        kubernetesGateway = {
          enabled = true
          statusAddress = {
            ip      = local.public_host
            service = { enabled = false }
          }
        }
        kubernetesIngress = {
          enabled = false
        }
      }
      # Gateway API only: no (default) IngressClass that nothing would serve
      ingressClass = {
        enabled = false
      }
      # Our Gateway comes from charts/gateway
      gateway = {
        enabled = false
      }
      gatewayClass = {
        enabled = true
        name    = "traefik"
      }
    })
  ]

  atomic  = true
  wait    = true
  timeout = 600

  depends_on = [kubernetes_manifest.gateway_api]
}

# =============================================================================
# cert-manager + Let's Encrypt
# ClusterIssuers letsencrypt-staging and letsencrypt-prod solve HTTP-01
# challenges with an HTTPRoute on the Gateway's port 80 listener, so no DNS
# access is needed.
# =============================================================================

locals {
  charts_dir = "${path.module}/../../charts"

  # Terraform only sees chart changes through its inputs, so each local chart
  # gets a hash of its files as a value: editing any of them triggers an upgrade.
  chart_checksum = {
    for c in ["nginx-hello-world", "letsencrypt-issuers", "gateway"] :
    c => sha256(join("", [for f in sort(fileset("${local.charts_dir}/${c}", "**")) : filesha256("${local.charts_dir}/${c}/${f}")]))
  }

  cert_manager_config = {
    apiVersion = "controller.config.cert-manager.io/v1alpha1"
    kind       = "ControllerConfiguration"
    gatewayAPI = { enabled = true }
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
      config = local.cert_manager_config
      # The chart does not restart the controller when its config changes
      podAnnotations = {
        "checksum/config" = sha256(jsonencode(local.cert_manager_config))
      }
    })
  ]

  atomic  = true
  wait    = true
  timeout = 600

  # Gateway API support only starts if the CRDs exist when the controller does
  depends_on = [kubernetes_manifest.gateway_api]
}

resource "helm_release" "letsencrypt_issuers" {
  name      = "letsencrypt-issuers"
  chart     = "${local.charts_dir}/letsencrypt-issuers"
  namespace = helm_release.cert_manager.namespace

  values = [
    yamlencode({
      email  = var.letsencrypt_email
      solver = "gateway"
      gateway = {
        name        = local.gateway.name
        namespace   = local.gateway.namespace
        sectionName = "http"
      }
      chartChecksum = local.chart_checksum["letsencrypt-issuers"]
    })
  ]

  atomic = true
  wait   = true

  # The cert-manager webhook must be up to accept ClusterIssuers
  depends_on = [helm_release.cert_manager]
}

# =============================================================================
# Shared Gateway "public" in namespace gateway (charts/gateway): one HTTPS
# listener per hostname with a cert-manager certificate, HTTP -> HTTPS redirect
# =============================================================================

locals {
  # sslip.io resolves <a-b-c-d>.sslip.io to a.b.c.d, so no DNS record is needed
  hello_host = coalesce(var.hello_host, "hello.${replace(local.public_host, ".", "-")}.sslip.io")

  gateway = {
    name      = "public"
    namespace = "gateway"
  }
}

resource "helm_release" "gateway" {
  name             = "gateway"
  chart            = "${local.charts_dir}/gateway"
  namespace        = local.gateway.namespace
  create_namespace = true

  values = [
    yamlencode({
      name             = local.gateway.name
      gatewayClassName = "traefik"
      clusterIssuer    = "letsencrypt-${var.letsencrypt_environment}"
      routeNamespaces  = sort([for ns in kubernetes_namespace_v1.this : ns.metadata[0].name])
      hosts = {
        hello = local.hello_host
      }
      chartChecksum = local.chart_checksum["gateway"]
    })
  ]

  atomic = true
  wait   = true

  depends_on = [helm_release.traefik, helm_release.letsencrypt_issuers]
}

# =============================================================================
# nginx-hello-world: the local chart in charts/ at the repo root, routed by
# an HTTPRoute on the Gateway's https-hello listener (HTTPS at hello_host).
# =============================================================================

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
      httpRoute = {
        enabled = true
        parentRefs = [{
          name        = local.gateway.name
          namespace   = local.gateway.namespace
          sectionName = "https-hello"
        }]
        hostnames = [local.hello_host]
      }
      podAnnotations = {
        "checksum/chart" = local.chart_checksum["nginx-hello-world"]
      }
    })
  ]

  atomic  = true
  wait    = true
  timeout = 300

  depends_on = [helm_release.gateway]
}
