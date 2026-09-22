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
  description = "Number of k0s node instances to launch. Multi-node cluster: 1 controller + N workers (3 = 1+2)."
  type        = number
  default     = 3

  validation {
    condition     = var.instance_count >= 1
    error_message = "instance_count must be 1 or greater."
  }
}

variable "public_key_path" {
  description = "Path to an OpenSSH public key file used to create the EC2 key pair. Not used by Terraform Cloud — set to a key pair you import there instead."
  type        = string
  default     = "~/.k0stool/k0stool-key.pub"
}