# --- From the networking module -------------------------------------------
variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "load_balancer_enabled" {
  description = "The API endpoint is the load balancer, and the nodes are registered as its targets"
  type        = bool
  default     = false
}

variable "load_balancer_ip" {
  description = "Fixed public IP of the load balancer"
  type        = string
  default     = null
}

variable "load_balancer_security_group_id" {
  type    = string
  default = null
}

variable "target_group_arns" {
  description = "Load balancer target groups by name: api, http, https"
  type        = map(string)
  default     = {}
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

# --- Instance ---------------------------------------------------------------
variable "control_plane_count" {
  description = "Number of control plane nodes (1, 3 or 5). More than one needs the load balancer"
  type        = number
  default     = 1
}

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

variable "data_disk_size" {
  description = "Size in GiB of the separate disk per node for persistent volumes, mounted at /var/mnt/local-storage. 0 = none"
  type        = number
  default     = 0
}

variable "tags" {
  type    = map(string)
  default = {}
}
