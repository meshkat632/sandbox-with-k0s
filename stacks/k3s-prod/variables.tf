variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "k3s-prod"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must not overlap K3s pod/service ranges (10.42/16, 10.43/16)."
  type        = string
  default     = "10.30.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && !contains(["10.42", "10.43"], join(".", slice(split(".", var.vpc_cidr), 0, 2)))
    error_message = "vpc_cidr must be a valid CIDR and must not use 10.42.x or 10.43.x."
  }
}

variable "azs" {
  description = "Availability zones (one public + one private subnet each)."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  validation {
    condition     = length(var.azs) >= 1 && length(var.azs) <= 6
    error_message = "Use 1 to 6 availability zones."
  }
}

variable "tags" {
  description = "Extra tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "allowed_cidrs" {
  description = "External CIDRs allowed to reach the kube API through the public NLB, e.g. [\"203.0.113.7/32\"]. The VPC itself is always allowed on the API."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Each entry of allowed_cidrs must be a valid CIDR block."
  }

  validation {
    condition     = !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "allowed_cidrs must not contain 0.0.0.0/0."
  }
}

# --- K3s ---------------------------------------------------------------------
variable "server_count" {
  description = "K3s server nodes (embedded etcd requires 3 for HA)."
  type        = number
  default     = 3
}

variable "instance_type" {
  description = "EC2 instance type for the server nodes (2 vCPU / 4 GB is the comfortable minimum for etcd + k3s)."
  type        = string
  default     = "t3a.medium"
}

variable "k3s_version" {
  description = "Pinned K3s release."
  type        = string
  default     = "v1.31.7+k3s1"
}

variable "cluster_cidr" {
  description = "K3s pod CIDR. Must not overlap vpc_cidr."
  type        = string
  default     = "10.42.0.0/16"
}

variable "service_cidr" {
  description = "K3s service CIDR. Must not overlap vpc_cidr."
  type        = string
  default     = "10.43.0.0/16"
}
