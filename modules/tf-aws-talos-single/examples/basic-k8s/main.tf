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
# Its Service carries prometheus.io/scrape, which is how Prometheus finds it.
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
# Prometheus
# Server only: the chart's bundled kube-state-metrics, node-exporter,
# Alertmanager and Pushgateway are off. Its default scrape config picks up
# every Service annotated prometheus.io/scrape (kube-state-metrics above),
# plus the API server, kubelets and cAdvisor.
# No StorageClass in this cluster, so data lives in an emptyDir and is lost
# when the pod is rescheduled.
# =============================================================================
resource "helm_release" "prometheus" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus"
  version          = var.prometheus_chart_version
  namespace        = "monitoring"
  create_namespace = true

  values = [
    yamlencode({
      server = {
        persistentVolume = {
          enabled = false
        }
        retention = "2d"
      }
      alertmanager = {
        enabled = false
      }
      "kube-state-metrics" = {
        enabled = false
      }
      "prometheus-node-exporter" = {
        enabled = false
      }
      "prometheus-pushgateway" = {
        enabled = false
      }
    })
  ]

  atomic  = true
  wait    = true
  timeout = 600

  depends_on = [helm_release.kube_state_metrics]
}

# =============================================================================
# Grafana
# Prometheus above as the default datasource, plus the kube-state-metrics
# dashboard from dashboards/. No persistence: anything changed in the UI is
# lost when the pod restarts, the provisioned dashboard comes back.
# The admin password is generated into the "grafana" Secret.
# =============================================================================
resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "grafana"
  version    = var.grafana_chart_version
  namespace  = helm_release.prometheus.namespace

  values = [
    yamlencode({
      datasources = {
        "datasources.yaml" = {
          apiVersion = 1
          datasources = [{
            name      = "Prometheus"
            type      = "prometheus"
            uid       = "prometheus" # referenced by the dashboard
            url       = "http://prometheus-server.${helm_release.prometheus.namespace}.svc"
            access    = "proxy"
            isDefault = true
          }]
        }
      }
      dashboardProviders = {
        "dashboardproviders.yaml" = {
          apiVersion = 1
          providers = [{
            name            = "default"
            orgId           = 1
            folder          = ""
            type            = "file"
            disableDeletion = false
            editable        = true
            options = {
              path = "/var/lib/grafana/dashboards/default"
            }
          }]
        }
      }
      dashboards = {
        default = {
          "kube-state-metrics" = {
            json = file("${path.module}/dashboards/kube-state-metrics.json")
          }
        }
      }
    })
  ]

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
