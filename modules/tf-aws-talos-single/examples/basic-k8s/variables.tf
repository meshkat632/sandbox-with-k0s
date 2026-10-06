variable "cluster_organization" {
  description = "HCP Terraform organization of the cluster workspace"
  type        = string
  default     = "sandbox-v1"
}

variable "cluster_workspace" {
  description = "HCP Terraform workspace of examples/basic (source of the kubeconfig)"
  type        = string
  default     = "talos-single-test"
}

variable "metrics_server_chart_version" {
  description = "metrics-server Helm chart version"
  type        = string
  default     = "3.14.0"
}

variable "kube_state_metrics_chart_version" {
  description = "kube-state-metrics Helm chart version"
  type        = string
  default     = "8.6.0"
}

variable "ingress_nginx_chart_version" {
  description = "ingress-nginx Helm chart version"
  type        = string
  default     = "4.15.1"
}

variable "cert_manager_chart_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.21.2"
}
