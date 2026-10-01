variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-central-1"
}

variable "name" {
  description = "Name prefix for all resources. Must match resource_prefix in bootstrap-oidc if you use it."
  type        = string
  default     = "k3k-host"
}

variable "instance_type" {
  description = "EC2 instance type for the single K3s node."
  type        = string
  default     = "t3.large"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 40
}

variable "subnet_id" {
  description = "Optional subnet in the default VPC. Leave null to use the first default subnet."
  type        = string
  default     = null
}

variable "k3s_version" {
  description = "Exact K3s version to install (e.g. v1.33.5+k3s1). Empty = latest from k3s_channel."
  type        = string
  default     = ""
}

variable "k3s_channel" {
  description = "K3s release channel used when k3s_version is empty."
  type        = string
  default     = "stable"
}

variable "extra_tls_sans" {
  description = "Extra DNS names / IPs to add to the K3s API server certificate."
  type        = list(string)
  default     = []
}

/*
variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API server on 6443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
*/
variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the K3s API (6443) and NodePorts (30000-32767)."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "allowed_cidrs must contain at least one valid CIDR, e.g. [\"217.88.120.161/32\"]."
  }
}

variable "nodeport_allowed_cidrs" {
  description = "CIDRs allowed to reach NodePorts 30000-32767 (needed later for the K3k HCP apiserver). Empty = closed."
  type        = list(string)
  default     = []
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH on port 22. Empty = closed (use SSM Session Manager instead)."
  type        = list(string)
  default     = []
}

variable "key_name" {
  description = "Optional existing EC2 key pair name for SSH."
  type        = string
  default     = null
}

variable "enable_ssm" {
  description = "Attach AmazonSSMManagedInstanceCore so you can shell in via SSM without opening SSH."
  type        = bool
  default     = true
}

variable "kubeconfig_secret_name" {
  description = "Name of the Secrets Manager secret that receives the kubeconfig."
  type        = string
  default     = "k3k-host/kubeconfig"
}

variable "tags" {
  description = "Extra tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "allow_runner_ip" {
  description = "Whitelist the public IP of the machine running Terraform. Only meaningful with LOCAL execution."
  type        = bool
  default     = true
}


variable "wait_for_ready" {
  description = "Make terraform apply wait until K3s is ready. Needs bash, curl and the aws CLI where Terraform runs."
  type        = bool
  default     = true
}

variable "wait_timeout_seconds" {
  type    = number
  default = 600
}