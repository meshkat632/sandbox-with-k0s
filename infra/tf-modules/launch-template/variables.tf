variable "name" {
  description = "Name for the launch template, and the Name tag on launched instances and volumes"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for launched instances"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "AMI for launched instances. Defaults to the latest Ubuntu 24.04 (Noble) amd64 image in the region"
  type        = string
  default     = null
}

variable "key_name" {
  description = "EC2 key pair name for SSH access. Null launches instances without an SSH key"
  type        = string
  default     = null
}

variable "security_group_ids" {
  description = "Security groups attached to launched instances"
  type        = list(string)
  default     = []
}

variable "iam_instance_profile_name" {
  description = "IAM instance profile name to attach to launched instances, e.g. for SSM access"
  type        = string
  default     = null
}

variable "user_data" {
  description = "Raw (not base64-encoded) cloud-init/user-data script run at first boot"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags applied to the template, launched instances, and volumes"
  type        = map(string)
  default     = {}
}
