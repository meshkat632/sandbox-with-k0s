variable "secret_name" {
  description = "AWS Secrets Manager secret name to hold the cluster's admin kubeconfig"
  type        = string
}

variable "recovery_window_in_days" {
  description = "Days before permanent deletion. 0 = delete immediately (no recovery window) — useful for sandbox/test secrets."
  type        = number
  default     = 0
}

variable "tags" {
  description = "Tags applied to the secret"
  type        = map(string)
  default     = {}
}
