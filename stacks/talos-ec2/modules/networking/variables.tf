variable "cluster_name" {
  description = "Name prefix for the security group"
  type        = string
}

variable "http_ingress_cidrs" {
  description = "CIDRs allowed on 80/443. Empty list = no HTTP rules"
  type        = list(string)
  default     = []
}

variable "load_balancer_enabled" {
  description = "Create a Network Load Balancer with a fixed IP for the Kubernetes API (6443) and the ingress (80/443)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
