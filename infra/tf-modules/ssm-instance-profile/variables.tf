variable "name" {
  description = "Name prefix for the role and instance profile"
  type        = string
}

variable "tags" {
  description = "Extra tags applied to the role and instance profile"
  type        = map(string)
  default     = {}
}

variable "extra_policy_arns" {
  description = "Additional IAM managed policy ARNs to attach to the instance role"
  type        = list(string)
  default     = []
}
