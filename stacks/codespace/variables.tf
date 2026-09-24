variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.region))
    error_message = "region must be an AWS region name, e.g. \"eu-central-1\"."
  }
}

variable "name_suffix" {
  description = "Fixed name suffix. If null, a random 6-char hex suffix is generated."
  type        = string
  default     = null

  validation {
    condition     = var.name_suffix == null || can(regex("^[a-z0-9][a-z0-9-]{0,19}$", var.name_suffix))
    error_message = "name_suffix must be 1-20 lowercase letters, digits or hyphens, starting with a letter or digit."
  }
}

variable "tags" {
  description = "Tags applied to every resource through the provider's default_tags."
  type        = map(string)
  default = {
    Project     = "codespace"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach SSH (22) and the Kubernetes API (6443), e.g. [\"203.0.113.10/32\"]."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Provide at least one valid CIDR block."
  }

  validation {
    condition     = !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 would expose SSH and the Kubernetes API to the internet; list specific CIDRs."
  }
}

variable "web_allowed_cidrs" {
  description = "CIDRs allowed to reach HTTP (80) and HTTPS (443) on the instance, where Traefik serves the Gateway. Unlike allowed_cidrs, the whole internet is fine here; [] closes both ports."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.web_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Each entry of web_allowed_cidrs must be a valid CIDR block."
  }
}

variable "subnet_id" {
  description = "Subnet for the instance. If null, the first default subnet of the default VPC is used."
  type        = string
  default     = null

  validation {
    condition     = var.subnet_id == null || can(regex("^subnet-[0-9a-f]+$", var.subnet_id))
    error_message = "subnet_id must look like \"subnet-0123abcd\"."
  }
}

variable "instance_type" {
  description = "EC2 instance type. Must support x86_64."
  type        = string
  default     = "r7i.2xlarge"
}

variable "root_volume_size" {
  description = "Root volume size in GiB."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_size >= 20 && var.root_volume_size <= 16384
    error_message = "root_volume_size must be between 20 and 16384 GiB."
  }
}

variable "python_packages" {
  description = "pip requirement specifiers installed into ~/.venvs/dev by the bootstrap script."
  type        = list(string)
  default     = ["numpy", "pandas", "requests", "ruff", "pytest"]

  # These are interpolated into a shell script, so only allow characters that
  # can appear in a pip requirement specifier.
  validation {
    condition     = alltrue([for p in var.python_packages : can(regex("^[A-Za-z0-9][A-Za-z0-9._\\-\\[\\],<>=!~]*$", p))])
    error_message = "Each python_packages entry must be a plain pip requirement such as \"requests\" or \"numpy>=2\"."
  }
}

variable "k0s_version" {
  description = "k0s release to install, e.g. \"v1.36.4+k0s.1\". Pinned so every rebuild gets the same cluster; the binary is verified against the release's sha256sums.txt."
  type        = string
  default     = "v1.36.4+k0s.1"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+k0s\\.[0-9]+$", var.k0s_version))
    error_message = "k0s_version must be a k0s release tag such as \"v1.36.4+k0s.1\"."
  }
}

variable "extra_policy_arns" {
  description = "Managed policies attached to the instance role in addition to SSM."
  type        = list(string)
  default = [
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ]

  validation {
    condition     = alltrue([for a in var.extra_policy_arns : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/.+$", a))])
    error_message = "Each extra_policy_arns entry must be an IAM policy ARN."
  }
}

variable "kubeconfig_secret_name" {
  description = "Secrets Manager secret holding the cluster kubeconfig. Fixed (no random suffix) so `make kubeconfig` can find it without Terraform; keep it in sync with KUBECONFIG_SECRET in the Makefile."
  type        = string
  default     = "codespace-kubeconfig"

  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]{1,512}$", var.kubeconfig_secret_name))
    error_message = "kubeconfig_secret_name may only contain letters, digits and /_+=.@- (max 512 characters)."
  }
}

variable "kubeconfig_recovery_window_in_days" {
  description = "Days Secrets Manager keeps the kubeconfig secret after deletion. 0 deletes it immediately, so the same name can be reused right away."
  type        = number
  default     = 0

  validation {
    condition     = var.kubeconfig_recovery_window_in_days == 0 || (var.kubeconfig_recovery_window_in_days >= 7 && var.kubeconfig_recovery_window_in_days <= 30)
    error_message = "kubeconfig_recovery_window_in_days must be 0 or between 7 and 30."
  }
}

variable "upload_dir" {
  description = "Folder, relative to this stack, whose files are copied to upload_destination on the instance through SSM. Hidden files are skipped; an empty folder uploads nothing."
  type        = string
  default     = "files"
}

variable "upload_destination" {
  description = "Directory on the instance that mirrors upload_dir. Managed entirely by Terraform: files not in upload_dir are removed."
  type        = string
  default     = "/opt/codespace/files"

  validation {
    condition     = can(regex("^/[A-Za-z0-9._/-]+[A-Za-z0-9._-]$", var.upload_destination)) && !contains(["/", "/opt", "/opt/codespace", "/etc", "/usr", "/home", "/root", "/var"], trimsuffix(var.upload_destination, "/"))
    error_message = "upload_destination must be an absolute path of letters, digits and ._-/ and not a system directory such as /opt/codespace or /etc."
  }
}
