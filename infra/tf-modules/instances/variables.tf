variable "name" {
  description = "Name prefix for the instances. Each instance gets Name = <name>-<index>"
  type        = string
}

variable "launch_template_id" {
  description = "ID of the launch template to launch instances from"
  type        = string
}

variable "launch_template_version" {
  description = "Launch template version to use"
  type        = string
  default     = "$Latest"
}

variable "subnet_ids" {
  description = "Subnet IDs to spread instances across, round-robin by index"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids must be a non-empty list."
  }
}

variable "instance_count" {
  description = "Number of instances to launch"
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 0
    error_message = "instance_count must be 0 or greater."
  }
}

variable "tags" {
  description = "Extra tags applied to each instance"
  type        = map(string)
  default     = {}
}
