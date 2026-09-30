# =============================================================================
# ingress-nginx: IngressClass "nginx", alongside Traefik's Gateway API.
# Traefik already binds ports 80/443 of the node (hostPort), so ingress-nginx
# is reached via fixed NodePorts; the codespace stack's security group must
# open them. SSL passthrough is enabled so Ingresses can forward TLS unchanged
# to their backend (annotation nginx.ingress.kubernetes.io/ssl-passthrough).
# =============================================================================

variable "ingress_nginx_chart_version" {
  description = "ingress-nginx Helm chart version (helm search repo ingress-nginx/ingress-nginx)"
  type        = string
  default     = "4.15.1"
}

variable "ingress_nginx_node_ports" {
  description = "NodePorts on which ingress-nginx serves HTTP and HTTPS"
  type = object({
    http  = number
    https = number
  })
  default = {
    http  = 30080
    https = 30443
  }
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
        service = {
          type      = "NodePort"
          nodePorts = var.ingress_nginx_node_ports
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

output "ingress_nginx_https_url" {
  description = "Base URL of ingress-nginx's HTTPS NodePort"
  value       = "https://${local.public_host}:${var.ingress_nginx_node_ports.https}"
}