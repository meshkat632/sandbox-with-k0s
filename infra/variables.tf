variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "Region must be a valid AWS region identifier, e.g. eu-central-1."
  }
}

variable "key_name" {
  description = "Name of the EC2 key pair used for SSH access to cluster nodes."
  type        = string

  validation {
    condition     = length(var.key_name) <= 255 && can(regex("^[a-zA-Z0-9._-]+$", var.key_name))
    error_message = "Key name must be 1-255 characters of letters, digits, dot, underscore, hyphen."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets, one per availability zone in order. Must fall inside vpc_cidr."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = alltrue([for c in var.public_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "public_subnet_cidrs must be a list of valid IPv4 CIDR blocks."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the k0s nodes. t3a.large (8 GB) is the minimum for a multi-node k0s cluster."
  type        = string
  default     = "t3a.large"
}

variable "ssh_cidr" {
  description = "CIDR block allowed to reach the instance on port 22. '0.0.0.0/0' means SSH from anywhere."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.ssh_cidr, 0))
    error_message = "ssh_cidr must be a valid IPv4 CIDR block."
  }
}

variable "kube_api_cidrs" {
  description = "CIDR blocks allowed to reach the Kubernetes API (port 6443) from outside the VPC. Empty (default) means no external access — use an SSM port-forward tunnel instead (see scripts/get_kubeconfig.sh)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.kube_api_cidrs : can(cidrhost(c, 0))])
    error_message = "kube_api_cidrs must be a list of valid IPv4 CIDR blocks."
  }
}

variable "environment" {
  description = "Deployment environment. Drives tagging and access policies."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "instance_count" {
  description = "Number of k0s node instances to launch. Start at 1 (bootstrap it as a controller with --enable-worker for a fully working single-node cluster), then raise this and join the new instances as workers — see scripts/join_workers.sh. Raising it never touches existing instances (aws_instance is count-indexed: new nodes just get appended at the next index); lowering it destroys the highest-indexed ones, so don't lower it below the number of nodes you've actually bootstrapped."
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 1
    error_message = "instance_count must be 1 or greater."
  }
}

variable "public_key_path" {
  description = "Path to a local OpenSSH public key file used to create the EC2 key pair. Only usable where Terraform runs against your own filesystem — not Terraform Cloud, which sandboxes runs away from any local disk. Ignored if var.public_key is set."
  type        = string
  default     = "~/.k0stool/k0stool-key.pub"
}

variable "public_key" {
  description = "Raw OpenSSH public key content (e.g. the contents of k0stool-key.pub) for the EC2 key pair. Takes precedence over public_key_path — set this as a Terraform Cloud workspace variable, since TFC runs can't read a local file."
  type        = string
  default     = null
}
