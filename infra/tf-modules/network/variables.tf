variable "name" {
  description = "Name prefix used for all resources and their Name tags"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, one per availability zone in order"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) > 0 && alltrue([for c in var.public_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "public_subnet_cidrs must be a non-empty list of valid IPv4 CIDR blocks."
  }
}

variable "ssh_cidr" {
  description = "CIDR block allowed to reach instances on port 22"
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.ssh_cidr, 0))
    error_message = "ssh_cidr must be a valid IPv4 CIDR block."
  }
}

variable "tags" {
  description = "Extra tags applied to all resources"
  type        = map(string)
  default     = {}
}
