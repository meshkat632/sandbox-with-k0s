variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "k3s-prod"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must not overlap K3s pod/service ranges (10.42/16, 10.43/16)."
  type        = string
  default     = "10.30.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && !contains(["10.42", "10.43"], join(".", slice(split(".", var.vpc_cidr), 0, 2)))
    error_message = "vpc_cidr must be a valid CIDR and must not use 10.42.x or 10.43.x."
  }
}

variable "azs" {
  description = "Availability zones (one public + one private subnet each)."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  validation {
    condition     = length(var.azs) >= 1 && length(var.azs) <= 6
    error_message = "Use 1 to 6 availability zones."
  }
}

variable "tags" {
  description = "Extra tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "allowed_cidrs" {
  description = "External CIDRs allowed to reach the kube API through the public NLB, e.g. [\"203.0.113.7/32\"]. The VPC itself is always allowed on the API."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Each entry of allowed_cidrs must be a valid CIDR block."
  }

  validation {
    condition     = !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "allowed_cidrs must not contain 0.0.0.0/0."
  }
}

# --- K3s ---------------------------------------------------------------------
variable "server_count" {
  description = "K3s server nodes. 1 = single control plane, no HA; embedded etcd needs 3 for HA."
  type        = number
  default     = 1
}

variable "instance_type" {
  description = "EC2 instance type for the server nodes (2 vCPU / 4 GB is the comfortable minimum for etcd + k3s)."
  type        = string
  default     = "t3a.medium"
}

variable "k3s_version" {
  description = "Pinned K3s release."
  type        = string
  default     = "v1.31.7+k3s1"
}

variable "cluster_cidr" {
  description = "K3s pod CIDR. Must not overlap vpc_cidr."
  type        = string
  default     = "10.42.0.0/16"
}

variable "service_cidr" {
  description = "K3s service CIDR. Must not overlap vpc_cidr."
  type        = string
  default     = "10.43.0.0/16"
}

variable "etcd_snapshot_schedule" {
  description = "Cron schedule for etcd snapshots; every snapshot is also uploaded to the cluster's S3 bucket."
  type        = string
  default     = "0 */6 * * *"
}

variable "etcd_snapshot_retention" {
  description = "Scheduled etcd snapshots to keep (per server, locally and in S3). 28 = one week at the default schedule."
  type        = number
  default     = 28
}

variable "etcd_snapshot_bucket_force_destroy" {
  description = "Let `terraform destroy` delete the snapshot bucket even when it still holds snapshots. Deletes the backups for good; apply the change before destroying."
  type        = bool
  default     = false
}

variable "restore_snapshot" {
  description = "Name of a snapshot in the cluster's S3 bucket (see `make snapshots`). When set, a newly created server 0 restores etcd from it on first boot instead of starting an empty cluster. Only affects new instances; needs the join token the snapshot was taken with (kept by `make destroy`)."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]*$", var.restore_snapshot))
    error_message = "restore_snapshot must be a bare snapshot name, e.g. etcd-snapshot-k3s-server-0-1790940000."
  }
}

# --- Worker node pools --------------------------------------------------------
variable "node_pools" {
  description = "Worker node pools: pool name => settings. Each pool is an Auto Scaling group of `size` K3s agents, labelled node-pool=<name> and compute-class=<compute_class>. Several pools may share a compute class. Taints use K3s syntax, e.g. \"dedicated=batch:NoSchedule\". {} means no workers."
  type = map(object({
    compute_class = optional(string, "general-purpose")
    instance_type = optional(string, "t3a.medium")
    size          = optional(number, 2)
    disk_size     = optional(number, 30)
    labels        = optional(map(string), {})
    taints        = optional(list(string), [])
  }))
  default = {
    default = {}
  }

  validation {
    condition     = alltrue([for name, _ in var.node_pools : can(regex("^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$", name))])
    error_message = "Pool names must be 1-20 characters of lowercase letters, digits and dashes."
  }

  validation {
    condition     = alltrue([for _, p in var.node_pools : can(regex("^[A-Za-z0-9]([A-Za-z0-9._-]{0,61}[A-Za-z0-9])?$", p.compute_class))])
    error_message = "compute_class must be a valid Kubernetes label value: up to 63 letters, digits, dashes, dots or underscores, starting and ending with a letter or digit."
  }

  validation {
    condition     = alltrue([for _, p in var.node_pools : p.size >= 0 && p.disk_size >= 20])
    error_message = "Each pool needs size >= 0 and disk_size >= 20 (GB)."
  }
}
