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

variable "cert_manager_chart_version" {
  description = "Version of the cert-manager Helm chart."
  type        = string
  default     = "v1.21.2"
}

variable "letsencrypt_email" {
  description = "Email for the Let's Encrypt account (expiry and account notices)."
  type        = string
  default     = "meshkat632@gmail.com"

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.letsencrypt_email))
    error_message = "letsencrypt_email must be an email address."
  }
}

variable "letsencrypt_environment" {
  description = "Let's Encrypt server for the Gateway's certificates: \"staging\" (untrusted certificates, generous rate limits) or \"prod\"."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["staging", "prod"], var.letsencrypt_environment)
    error_message = "letsencrypt_environment must be \"staging\" or \"prod\"."
  }
}

variable "hello_host" {
  description = "Hostname of the hello-world app. It must resolve to the instance's Elastic IP. Null means hello.<ip-with-dashes>.sslip.io."
  type        = string
  default     = null
}

variable "gateway_api_version" {
  description = "Gateway API release whose standard-channel CRDs are installed. Keep it at a version the Traefik chart supports."
  type        = string
  default     = "v1.5.1"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.gateway_api_version))
    error_message = "gateway_api_version must look like v1.5.1."
  }
}

variable "traefik_chart_version" {
  description = "Version of the Traefik Helm chart."
  type        = string
  default     = "41.6.0"
}
