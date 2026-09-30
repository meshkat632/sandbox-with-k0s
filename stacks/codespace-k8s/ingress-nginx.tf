# =============================================================================
# ingress-nginx
# Serves Ingresses of class "nginx". The Service is ClusterIP only: Traefik
# owns ports 80/443 of the node and nothing routes outside traffic here yet.
# =============================================================================

variable "ingress_nginx_chart_version" {
  description = "ingress-nginx Helm chart version"
  type        = string
  default     = "4.15.1"
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
        # No cloud load balancer and no free host ports, so no NodePorts
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
