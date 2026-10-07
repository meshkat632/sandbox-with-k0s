variable "cluster_name" {
  description = "Name prefix for the security group"
  type        = string
}

variable "http_ingress_cidrs" {
  description = "CIDRs allowed on 80/443. Empty list = no HTTP rules"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
