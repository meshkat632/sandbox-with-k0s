variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-central-1"
}

variable "key_name" {
  description = "Name for the AWS key pair"
  type        = string
  default     = "k0stool-key"
}

variable "public_key" {
  type      = string
  sensitive = true
}