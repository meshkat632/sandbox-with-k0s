# =============================================================================
# Secrets & naming
# =============================================================================

data "sops_file" "secrets" {
  source_file = "${path.module}/secrets.yaml"
}

resource "random_id" "uuid" {
  count       = var.name_suffix == null ? 1 : 0
  byte_length = 3
}

locals {
  suffix = coalesce(var.name_suffix, one(random_id.uuid[*].hex))
  name   = "codespace-${local.suffix}" # e.g. codespace-a3f9c1

  # Public key data only - private_key stripped out
  ssh_keys = [
    for k in nonsensitive(yamldecode(data.sops_file.secrets.raw).ssh_keys) : { for f, v in k : f => v if f != "private_key" }
  ]
}

# =============================================================================
# Step 1: lookups (read-only)
# =============================================================================

data "aws_vpc" "default" {
  count   = var.subnet_id == null ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.subnet_id == null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "this" {
  id = coalesce(var.subnet_id, try(sort(data.aws_subnets.default[0].ids)[0], null))
}

data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# =============================================================================
# Step 2: SSH key pair + security group
# =============================================================================

resource "aws_key_pair" "this" {
  key_name   = local.name
  public_key = local.ssh_keys[0].public_key

  lifecycle {
    precondition {
      condition     = can(regex("^ssh-", local.ssh_keys[0].public_key))
      error_message = "secrets.yaml must list at least one ssh_keys entry with an OpenSSH public_key."
    }
  }
}

resource "aws_security_group" "this" {
  name        = "${local.name}-sg"
  description = "SSH access to ${local.name}"
  vpc_id      = data.aws_subnet.this.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  ingress {
    description = "Kubernetes API (k0s)"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  dynamic "ingress" {
    for_each = length(var.web_allowed_cidrs) > 0 ? { HTTP = 80, HTTPS = 443 } : {}

    content {
      description = "${ingress.key} (ingress-nginx on the host ports)"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.web_allowed_cidrs
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-sg" }
}

# =============================================================================
# Step 3: IAM role + instance profile
# Gives the instance (and its k0s pods) temporary AWS credentials:
#   - SSM:     Session Manager shell + readiness check
#   - secret:  write access to the kubeconfig secret
#   - extras:  var.extra_policy_arns (EBS CSI volumes, ECR image pulls)
# =============================================================================

resource "aws_iam_role" "this" {
  name = "${local.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "extra" {
  for_each = toset(var.extra_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

# The instance publishes its own kubeconfig to this secret at the end of
# k0s.sh, so nothing outside AWS (e.g. a Terraform Cloud runner) ever has to
# reach it over SSH. The module also creates the placeholder version, which must
# exist before the instance boots (see depends_on on aws_instance.this).
module "kubeconfig_secret" {
  source = "./modules/kubeconfig-secret"

  secret_name             = var.kubeconfig_secret_name
  recovery_window_in_days = var.kubeconfig_recovery_window_in_days
}

resource "aws_iam_role_policy" "kubeconfig_push" {
  name = "kubeconfig-push"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:PutSecretValue"]
      Resource = module.kubeconfig_secret.secret_arn
    }]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${local.name}-profile"
  role = aws_iam_role.this.name
}

# =============================================================================
# Elastic IP: fixed public address that survives stop/start.
# Created before the instance so its address can be baked into the k0s
# API certificate; attached to the instance further down.
# =============================================================================

resource "aws_eip" "this" {
  domain = "vpc"
  tags   = { Name = local.name }
}

# =============================================================================
# Step 4: cloud-init scripts
# Each script is written to /opt/codespace/<name>.sh and run once on first
# boot, in list order. The chain stops at the first failing script.
# A marker /var/lib/codespace-<name>.done is written after each success.
# =============================================================================

locals {
  cloud_init_scripts = [
    {
      name = "bootstrap"
      content = templatefile("${path.module}/scripts/bootstrap.sh.tftpl", {
        name            = local.name
        python_packages = var.python_packages
      })
    },
    {
      name = "k0s"
      content = templatefile("${path.module}/scripts/k0s.sh.tftpl", {
        name        = local.name
        k0s_version = var.k0s_version
        public_ip   = aws_eip.this.public_ip
        region      = var.region
        secret_id   = module.kubeconfig_secret.secret_name
      })
    },
  ]

  user_data = "#cloud-config\n${yamlencode({
    write_files = [for s in local.cloud_init_scripts : {
      path        = "/opt/codespace/${s.name}.sh"
      owner       = "root:root"
      permissions = "0755"
      encoding    = "b64"
      content     = base64encode(s.content)
    }]
    runcmd = [join(" && ", [
      for s in local.cloud_init_scripts : "/opt/codespace/${s.name}.sh && touch /var/lib/codespace-${s.name}.done"
    ])]
  })}"
}

# =============================================================================
# Step 5: EC2 instance
# =============================================================================

resource "aws_instance" "this" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.this.id
  vpc_security_group_ids      = [aws_security_group.this.id]
  key_name                    = aws_key_pair.this.key_name
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = true

  # Any change to the scripts or their variables replaces the instance,
  # because cloud-init only runs user data on first boot.
  user_data                   = local.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # let pods (EBS CSI driver, ECR pulls) reach the instance role
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  tags = { Name = local.name }

  # Everything the boot scripts rely on must exist before the first boot:
  # the instance role's permissions, and the secret's placeholder version
  # (created later, it could overwrite the real kubeconfig).
  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy_attachment.extra,
    aws_iam_role_policy.kubeconfig_push,
    module.kubeconfig_secret,
  ]

  lifecycle {
    ignore_changes = [ami] # don't replace the server when Canonical publishes a newer AMI

    precondition {
      condition     = contains(data.aws_ec2_instance_type.this.supported_architectures, "x86_64")
      error_message = "instance_type ${var.instance_type} does not support x86_64; the AMI and k0s binary are amd64."
    }
  }
}

resource "aws_eip_association" "this" {
  instance_id   = aws_instance.this.id
  allocation_id = aws_eip.this.id
}



# how can I add a resource that would upload a folder full of script into the the instance