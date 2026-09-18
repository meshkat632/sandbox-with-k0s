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

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet. Must fall inside vpc_cidr."
  type        = string
  default     = "10.0.1.0/24"

  validation {
    condition     = can(cidrhost(var.public_subnet_cidr, 0))
    error_message = "public_subnet_cidr must be a valid IPv4 CIDR block."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the dev box."
  type        = string
  default     = "t3.micro"
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