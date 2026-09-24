# =============================================================================
# Provider
# =============================================================================

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "codespace"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

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

  secrets = yamldecode(data.sops_file.secrets.raw) # whole file (sensitive)

  db_username = nonsensitive(local.secrets.db.username)
  db_password = local.secrets.db.password # sensitive

  # Public key data only - private_key stripped out
  ssh_keys = [
    for k in nonsensitive(local.secrets.ssh_keys) : { for f, v in k : f => v if f != "private_key" }
  ]

  # Sensitive - used only by the SSH connection in step 6
  ssh_private_key = local.secrets.ssh_keys[0].private_key
}

# =============================================================================
# Step 1: lookups (read-only)
# =============================================================================

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
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
}

resource "aws_security_group" "this" {
  name        = "${local.name}-sg"
  description = "SSH access to ${local.name}"
  vpc_id      = data.aws_vpc.default.id

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
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
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

  lifecycle {
    ignore_changes = [ami] # don't replace the server when Canonical publishes a newer AMI
  }
}

resource "aws_eip_association" "this" {
  instance_id   = aws_instance.this.id
  allocation_id = aws_eip.this.id
}

# =============================================================================
# Step 6: wait until the instance is reachable and bootstrapped
# =============================================================================

resource "terraform_data" "instance_ready" {
  # Re-run the checks whenever the instance is replaced
  triggers_replace = [aws_instance.this.id]

  # AWS side: EC2 status checks pass and the SSM agent is Online
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ID=${aws_instance.this.id}
      REGION=${var.region}

      echo "Waiting for EC2 status checks on $ID ..."
      aws ec2 wait instance-status-ok --instance-ids "$ID" --region "$REGION"

      echo "Waiting for SSM agent to report Online ..."
      for i in $(seq 1 30); do
        STATUS=$(aws ssm describe-instance-information --region "$REGION" \
          --filters "Key=InstanceIds,Values=$ID" \
          --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || true)
        [ "$STATUS" = "Online" ] && { echo "SSM: Online"; exit 0; }
        echo "  SSM status: $STATUS (attempt $i/30)"; sleep 10
      done
      echo "ERROR: SSM agent not Online after 5 minutes" >&2; exit 1
    EOT
  }

  # Guest side: SSH works, cloud-init finished and every script succeeded
  connection {
    type        = "ssh"
    host        = aws_eip.this.public_ip
    user        = "ubuntu"
    private_key = local.ssh_private_key
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = concat(
      ["cloud-init status --wait > /dev/null || { sudo tail -n 40 /var/log/codespace-*.log; exit 1; }"],
      [for s in local.cloud_init_scripts : "test -f /var/lib/codespace-${s.name}.done"],
      [
        "kubectl get nodes",
        "echo \"ready: $(hostname) - $(lsb_release -ds)\"",
      ],
    )
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy_attachment.extra,
    aws_eip_association.this,
  ]
}

# =============================================================================
# Step 7: publish the kubeconfig to Secrets Manager
# Reads ~/.kube/config from the instance over SSH (server address is the
# Elastic IP, which is already an API cert SAN) and stores it in the secret,
# so `make kubeconfig` needs only AWS access - no SSH key. Re-runs whenever
# the instance or the secret is replaced.
# =============================================================================

module "kubeconfig_secret" {
  source = "../../infra/tf-modules/kubeconfig-secret"

  secret_name = var.kubeconfig_secret_name
}

resource "terraform_data" "kubeconfig_push" {
  triggers_replace = [aws_instance.this.id, module.kubeconfig_secret.secret_arn]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SSH_PRIVATE_KEY = local.ssh_private_key
      HOST            = aws_eip.this.public_ip
      SECRET_ID       = module.kubeconfig_secret.secret_arn
      AWS_REGION      = var.region
    }
    command = <<-EOT
      set -euo pipefail
      KEY=$(mktemp); trap 'rm -f "$KEY"' EXIT
      printf '%s\n' "$SSH_PRIVATE_KEY" > "$KEY"

      CFG=$(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR "ubuntu@$HOST" cat .kube/config)
      CFG=$(printf '%s\n' "$CFG" | sed -E "s#https://[^:]+:6443#https://$HOST:6443#")

      aws secretsmanager put-secret-value --secret-id "$SECRET_ID" \
        --secret-string "$CFG" > /dev/null
      echo "kubeconfig pushed to $SECRET_ID"
    EOT
  }

  # the placeholder version must exist first, or it could overwrite the real one
  depends_on = [terraform_data.instance_ready, module.kubeconfig_secret]
}

# =============================================================================
# Outputs
# =============================================================================

output "instance_id" {
  value = aws_instance.this.id
}

output "region" {
  value = var.region
}

output "public_ip" {
  value = aws_eip.this.public_ip
}

output "ssh_command" {
  value = "ssh ubuntu@${aws_eip.this.public_ip}"
}

output "kubeconfig_secret_name" {
  value      = module.kubeconfig_secret.secret_name
  depends_on = [terraform_data.kubeconfig_push]
}

output "ssm_command" {
  value = "aws ssm start-session --target ${aws_instance.this.id}"
}

output "debug" {
  value = {
    name        = local.name
    vpc_id      = data.aws_vpc.default.id
    ami_name    = data.aws_ami.ubuntu.name
    db_username = local.db_username
    db_password = "${substr(nonsensitive(local.db_password), 0, 2)}****" # masked
    db_pw_len   = nonsensitive(length(local.db_password))
    ssh_keys    = [for k in local.ssh_keys : k.name]
  }
}