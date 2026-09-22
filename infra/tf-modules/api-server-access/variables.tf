variable "security_group_id" {
  description = "ID of the existing security group to add API server access rules to"
  type        = string
}

variable "cidr_blocks" {
  description = "IPv4 CIDR blocks allowed to reach the API server port. Each gets its own rule, so blocks can be added or removed independently without touching the others."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.cidr_blocks : can(cidrhost(c, 0))])
    error_message = "cidr_blocks must be a list of valid IPv4 CIDR blocks."
  }
}

variable "port" {
  description = "TCP port the API server listens on"
  type        = number
  default     = 6443
}

variable "tags" {
  description = "Extra tags applied to each rule"
  type        = map(string)
  default     = {}
}
