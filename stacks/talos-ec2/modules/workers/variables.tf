variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
}

# --- From the networking module -------------------------------------------
variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

# --- From the talos module --------------------------------------------------
variable "control_plane_private_ip" {
  description = "Private IP of the control plane node; workers join the cluster through it"
  type        = string
}

variable "machine_secrets" {
  description = "Cluster secrets (talos_machine_secrets.machine_secrets)"
  type        = any
  sensitive   = true
}

variable "client_configuration" {
  description = "Talos API client certificate (talos_machine_secrets.client_configuration)"
  type        = any
  sensitive   = true
}

# --- Cluster ----------------------------------------------------------------
variable "cluster_name" {
  type = string
}

variable "talos_version" {
  description = "Talos contract version for the machine config, e.g. v1.11"
  type        = string
}

variable "talos_semver" {
  description = "Exact Talos release used for the AMI and installer image, e.g. v1.11.2"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version without the v prefix, e.g. 1.34.1"
  type        = string
}

variable "config_patches" {
  description = "Additional Talos machine-config patches (YAML strings)"
  type        = list(string)
  default     = []
}

# --- Instances --------------------------------------------------------------
variable "arch" {
  description = "amd64 or arm64 - must match the instance type"
  type        = string
}

variable "instance_type" {
  type = string
}

variable "disk_size" {
  description = "Root volume size in GiB"
  type        = number
}

variable "tags" {
  type    = map(string)
  default = {}
}
