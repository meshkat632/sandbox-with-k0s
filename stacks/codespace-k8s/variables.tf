variable "region" {
  description = "AWS region of the codespace stack (where its kubeconfig secret lives)."
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.region))
    error_message = "region must be an AWS region name, e.g. \"eu-central-1\"."
  }
}

variable "kubeconfig_secret_name" {
  description = "Secrets Manager secret the codespace instance publishes its admin kubeconfig to. Must match the codespace stack's kubeconfig_secret_name."
  type        = string
  default     = "codespace-kubeconfig"
}


variable "namespaces" {
  description = "Kubernetes namespaces to create in the codespace cluster."
  type        = set(string)
  default     = ["apps"]

  validation {
    condition     = alltrue([for n in var.namespaces : can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", n))])
    error_message = "Each namespace must be a valid DNS-1123 label: lowercase letters, digits and '-', at most 63 characters."
  }

  validation {
    condition     = length(setintersection(var.namespaces, ["default", "kube-system", "kube-public", "kube-node-lease"])) == 0
    error_message = "Built-in namespaces (default, kube-system, kube-public, kube-node-lease) already exist and must not be managed here."
  }
}

variable "ingress_nginx_chart_version" {
  description = "Version of the ingress-nginx Helm chart."
  type        = string
  default     = "4.15.1"
}
