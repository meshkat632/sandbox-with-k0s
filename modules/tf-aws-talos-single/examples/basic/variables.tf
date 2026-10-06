variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "name" {
  description = "Cluster name, also used as the Project tag"
  type        = string
  default     = "talos-single-test"
}

variable "tags" {
  description = "Extra tags applied to all AWS resources"
  type        = map(string)
  default     = {}
}

variable "worker_count" {
  description = "Extra worker nodes (0 = single-node cluster)"
  type        = number
  default     = 0
}

variable "http_ingress_cidrs" {
  description = "Who may reach ports 80/443 on the nodes (ingress-nginx from examples/basic-k8s). [] closes them"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
