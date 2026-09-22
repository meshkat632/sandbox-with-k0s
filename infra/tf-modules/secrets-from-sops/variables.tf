variable "source_file" {
  description = "Path to the sops-encrypted secrets file"
  type        = string
}

variable "secret_name" {
  description = "Name for the AWS Secrets Manager secret"
  type        = string
}

variable "expose_debug_output" {
  description = "If true, exposes the decrypted content as a sensitive output (for testing only)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to the secret"
  type        = map(string)
  default     = {}
}

variable "recovery_window_in_days" {
  type        = number
  default     = 0
  description = "Days before permanent deletion. Set to 0 to delete immediately (no recovery window) — useful for sandbox/test secrets."
}