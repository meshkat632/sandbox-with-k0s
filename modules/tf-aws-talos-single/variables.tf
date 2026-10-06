variable "cluster_name" {
  description = "Name of the Talos cluster (and the EC2 instance)"
  type        = string
}

variable "talos_version" {
  description = "Talos version contract for generated configs (e.g. v1.12). Also used to find the official AMI."
  type        = string
  default     = "v1.12"
}

variable "talos_semver" {
  description = "Exact Talos release used in the AMI lookup URL, e.g. v1.12.6"
  type        = string
  default     = "v1.12.6"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the guest cluster"
  type        = string
  default     = "1.33.0"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.large"
}

variable "worker_count" {
  description = "Number of extra worker nodes joined to the single control plane (0 = single-node cluster)"
  type        = number
  default     = 0

  validation {
    condition     = var.worker_count >= 0 && floor(var.worker_count) == var.worker_count
    error_message = "worker_count must be a whole number >= 0."
  }
}

variable "disk_size" {
  description = "Root disk size in GiB (Talos puts kubelet ephemeral storage here)"
  type        = number
  default     = 100
}

variable "ami_id" {
  description = "Override AMI lookup. If null, resolves the official Talos AMI for region+arch from the release's cloud-images.json"
  type        = string
  default     = null
}

variable "amd64" {
  description = "Use amd64 AMI (false = arm64)"
  type        = bool
  default     = true
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach Talos API (50000) and kube API (6443)"
  type        = string
  default     = null # defaults to your current public IP
}

variable "http_ingress_cidrs" {
  description = "CIDRs allowed to reach ports 80 and 443 on the nodes (for an ingress controller). Empty = closed"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Extra tags for the instance"
  type        = map(string)
  default     = {}
}