# =============================================================================
# ingress-nginx behind Traefik
# Traefik owns ports 80/443 of the node. Every host under
#   *.nginx.<public-ip-dashed>.sslip.io
# is handed to ingress-nginx unchanged by a Gateway of its own:
#   443 -> TLS passthrough (TLSRoute) -> ingress-nginx:443 (nginx terminates TLS)
#   80  -> HTTPRoute                  -> ingress-nginx:80  (ACME HTTP-01, redirects)
# Apps then use plain Ingresses (class "nginx") with the ClusterIssuer
# letsencrypt-nginx; Terraform knows nothing about them.
# =============================================================================

variable "ingress_nginx_chart_version" {
  description = "ingress-nginx Helm chart version"
  type        = string
  default     = "4.15.1"
}

variable "tlsroute_api_version" {
  description = "API version of TLSRoute served by the installed Gateway API CRDs"
  type        = string
  default     = "v1"
}

locals {
  # e.g. *.nginx.3-127-121-145.sslip.io (sslip.io resolves any name containing the IP)
  nginx_domain = "nginx.${replace(local.public_host, ".", "-")}.sslip.io"

  acme_server = {
    prod    = "https://acme-v02.api.letsencrypt.org/directory"
    staging = "https://acme-staging-v02.api.letsencrypt.org/directory"
  }[var.letsencrypt_environment]
}

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
        ingressClassResource = {
          name    = "nginx"
          enabled = true
          default = false
        }
        # Only reached through Traefik, so no NodePorts
        service = {
          type = "ClusterIP"
        }
        extraArgs = {
          "enable-ssl-passthrough" = "true"
        }
      }
    })
  ]

  atomic  = true
  wait    = true
  timeout = 600
}

# --- Traefik -> ingress-nginx -------------------------------------------------

resource "kubernetes_manifest" "nginx_gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "nginx"
      namespace = helm_release.ingress_nginx.namespace
    }
    spec = {
      gatewayClassName = "traefik"
      listeners = [
        {
          name     = "http"
          port     = 8000
          protocol = "HTTP"
          hostname = "*.${local.nginx_domain}"
        },
        {
          name     = "tls"
          port     = 8443
          protocol = "TLS"
          hostname = "*.${local.nginx_domain}"
          tls      = { mode = "Passthrough" }
        },
      ]
    }
  }

  depends_on = [helm_release.traefik]
}

resource "kubernetes_manifest" "nginx_tlsroute" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/${var.tlsroute_api_version}"
    kind       = "TLSRoute"
    metadata = {
      name      = "nginx"
      namespace = helm_release.ingress_nginx.namespace
    }
    spec = {
      parentRefs = [{ name = "nginx", sectionName = "tls" }]
      hostnames  = ["*.${local.nginx_domain}"]
      rules = [{
        backendRefs = [{ name = "ingress-nginx-controller", port = 443 }]
      }]
    }
  }

  depends_on = [kubernetes_manifest.nginx_gateway]
}

resource "kubernetes_manifest" "nginx_httproute" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "nginx"
      namespace = helm_release.ingress_nginx.namespace
    }
    spec = {
      parentRefs = [{ name = "nginx", sectionName = "http" }]
      hostnames  = ["*.${local.nginx_domain}"]
      rules = [{
        backendRefs = [{ name = "ingress-nginx-controller", port = 80 }]
      }]
    }
  }

  depends_on = [kubernetes_manifest.nginx_gateway]
}

# --- Let's Encrypt for Ingresses of class nginx --------------------------------

resource "kubernetes_manifest" "letsencrypt_nginx" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-nginx"
    }
    spec = {
      acme = {
        server              = local.acme_server
        email               = var.letsencrypt_email
        privateKeySecretRef = { name = "letsencrypt-nginx-account-key" }
        solvers = [{
          http01 = { ingress = { ingressClassName = "nginx" } }
        }]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}

output "nginx_domain" {
  description = "Hosts under *.<this> are served by ingress-nginx through Traefik"
  value       = local.nginx_domain
}