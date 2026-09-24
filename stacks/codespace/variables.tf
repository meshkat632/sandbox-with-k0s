variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "name_suffix" {
  description = "Fixed name suffix. If null, a random 6-char hex suffix is generated."
  type        = string
  default     = null
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to SSH in, e.g. [\"203.0.113.10/32\"]."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Provide at least one valid CIDR block."
  }
}

variable "instance_type" {
  description = "EC2 instance type (x86_64)."
  type        = string
  default     = "r7i.2xlarge"
}

variable "root_volume_size" {
  description = "Root volume size in GiB."
  type        = number
  default     = 100
}

variable "python_packages" {
  description = "pip packages installed into ~/.venvs/dev by the bootstrap script."
  type        = list(string)
  default     = ["numpy", "pandas", "requests", "ruff", "pytest"]
}

variable "k0s_version" {
  description = "k0s version to install, e.g. \"v1.33.4+k0s.0\". Empty string installs the latest stable."
  type        = string
  default     = ""
}

variable "extra_policy_arns" {
  description = "Managed policies attached to the instance role in addition to SSM."
  type        = list(string)
  default = [
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ]
}

variable "kubeconfig_secret_name" {
  description = "Secrets Manager secret holding the cluster kubeconfig. Fixed (no random suffix) so `make kubeconfig` can find it without Terraform; keep it in sync with KUBECONFIG_SECRET in the Makefile."
  type        = string
  default     = "codespace-kubeconfig"
}
