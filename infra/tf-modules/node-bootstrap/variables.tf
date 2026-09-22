variable "packages" {
  description = "apt packages to install on every node after apt-get update"
  type        = list(string)
  default = [
    "curl",       # fetches the k0s install script
    "unzip",      # unpacks release archives (awscli, etc.)
    "jq",         # JSON parsing in ad-hoc admin scripts
    "git",        # pulling manifests/configs on the node
    "open-iscsi", # required by the EBS CSI driver to attach volumes
  ]
}
