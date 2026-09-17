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

variable "public_key" {
  description = "OpenSSH public key content (the single line starting with ssh-ed25519). NEVER pass a private key here."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^ssh-(ed25519|rsa) ", trimspace(var.public_key)))
    error_message = "Public key must be an OpenSSH public key starting with 'ssh-ed25519 ' or 'ssh-rsa '."
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