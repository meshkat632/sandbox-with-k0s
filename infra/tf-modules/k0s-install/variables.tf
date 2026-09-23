variable "instance_id" {
  description = "Target EC2 instance ID to install k0s on"
  type        = string
}

variable "script_path" {
  description = "Path to install_k0s.py, e.g. \"$${path.root}/scripts/install_k0s.py\""
  type        = string
}

variable "role" {
  description = "k0s role to install"
  type        = string
  default     = "controller"

  validation {
    condition     = contains(["controller", "worker"], var.role)
    error_message = "role must be \"controller\" or \"worker\"."
  }
}

variable "enable_worker" {
  description = "controller only: also schedule pods on this node, so a single node is a fully working cluster on its own"
  type        = bool
  default     = false
}

variable "controller_ip" {
  description = "worker only: controller's private IP, for a pre-join connectivity check"
  type        = string
  default     = null
}

variable "token" {
  description = "worker only: join token from `k0s token create --role worker`, run on the controller. This module cannot generate it — the controller must already be up (see scripts/join_workers.sh for the fully-automated worker flow instead)."
  type        = string
  default     = null
  sensitive   = true
}

variable "wait_for_success_timeout_seconds" {
  description = "How long `terraform apply` blocks waiting for the install command to reach Success on the target instance (covers instance boot + SSM agent registration + the install itself, not just the command runtime). Applies fails if this is exceeded."
  type        = number
  default     = 600
}
