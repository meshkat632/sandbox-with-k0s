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
