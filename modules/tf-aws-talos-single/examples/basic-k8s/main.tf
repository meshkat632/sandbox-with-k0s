# =============================================================================
# metrics-server
# kubectl top + HPA. Talos kubelets serve self-signed certificates unless a
# serving-cert approver is installed, so skip verification (lab setup).
# =============================================================================
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"

  values = [
    yamlencode({
      args = ["--kubelet-insecure-tls"]
    })
  ]

  atomic  = true
  wait    = true
  timeout = 600
}

# =============================================================================
# kube-state-metrics
# Object state as Prometheus metrics on kube-state-metrics.kube-system:8080.
# Nothing scrapes it until a Prometheus is added.
# =============================================================================
resource "helm_release" "kube_state_metrics" {
  name       = "kube-state-metrics"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  version    = var.kube_state_metrics_chart_version
  namespace  = "kube-system"

  atomic  = true
  wait    = true
  timeout = 600
}

# =============================================================================
# ingress-nginx
# No cloud load balancer here, so the controller runs on every node and binds
# ports 80/443 there (hostPort). Talos enforces the "baseline" pod security
# level, which forbids host ports - the namespace has to be privileged.
# =============================================================================
resource "kubernetes_namespace_v1" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_chart_version
  namespace  = kubernetes_namespace_v1.ingress_nginx.metadata[0].name

  values = [
    yamlencode({
      controller = {
        kind = "DaemonSet"
        hostPort = {
          enabled = true
        }
        service = {
          type = "ClusterIP"
        }
        ingressClassResource = {
          name    = "nginx"
          enabled = true
          default = true
        }
      }
    })
  ]

  atomic  = true
  wait    = true
  timeout = 600
}

# =============================================================================
# cert-manager
# Controller and CRDs only - no issuers are created here.
# =============================================================================
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
      }
    })
  ]

  atomic  = true
  wait    = true
  timeout = 600
}
