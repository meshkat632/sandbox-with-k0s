variable "manifests_dir" {
  description = "Path to the folder containing the Kubernetes manifest files"
  type        = string
}

variable "file_pattern" {
  description = "Glob pattern (relative to manifests_dir) selecting the files to deploy"
  type        = string
  default     = "*.yaml"
}