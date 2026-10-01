

data "aws_caller_identity" "current" {}



data "http" "runner_ip" {
  count = var.allow_runner_ip ? 1 : 0
  url   = "https://checkip.amazonaws.com"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && can(cidrhost("${trimspace(self.response_body)}/32", 0))
      error_message = "Could not determine the runner's public IPv4 from checkip.amazonaws.com."
    }
  }
}

# ---------------------------------------------------------------------------
# Default VPC and subnet
# ---------------------------------------------------------------------------
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

locals {
  subnet_id = coalesce(var.subnet_id, sort(data.aws_subnets.default.ids)[0])
  runner_cidrs   = [for d in data.http.runner_ip : "${trimspace(d.response_body)}/32"]
  api_cidrs      = distinct(concat(var.allowed_cidrs, local.runner_cidrs))
  nodeport_cidrs = distinct(concat(local.api_cidrs, var.nodeport_allowed_cidrs))

}

# ---------------------------------------------------------------------------
# Ubuntu 24.04 LTS AMI (Canonical)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------
resource "aws_security_group" "k3s" {
  name        = "${var.name}-sg"
  description = "K3s host cluster"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.name}-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "api" {
  for_each = toset(local.api_cidrs)

  security_group_id = aws_security_group.k3s.id
  description       = "Kubernetes API server"
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "nodeports" {
  #for_each = toset(var.nodeport_allowed_cidrs)
  for_each = toset(local.nodeport_cidrs)

  security_group_id = aws_security_group.k3s.id
  description       = "Kubernetes NodePorts (K3k HCP apiserver)"
  ip_protocol       = "tcp"
  from_port         = 30000
  to_port           = 32767
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.k3s.id
  description       = "SSH"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.k3s.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Secret that will hold the kubeconfig (value is written by the instance)
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "kubeconfig" {
  name                    = var.kubeconfig_secret_name
  description             = "Admin kubeconfig for the ${var.name} K3s cluster (written by the instance on every boot)"
  recovery_window_in_days = 0 # allow immediate re-create after destroy
}

# ---------------------------------------------------------------------------
# Instance IAM role: may only write this one secret (+ optional SSM)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "publish_kubeconfig" {
  statement {
    actions = [
      "secretsmanager:PutSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.kubeconfig.arn]
  }
}

resource "aws_iam_role_policy" "publish_kubeconfig" {
  name   = "publish-kubeconfig"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.publish_kubeconfig.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count = var.enable_ssm ? 1 : 0

  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name}-node"
  role = aws_iam_role.node.name
}

# ---------------------------------------------------------------------------
# The K3s node (control plane + worker)
# ---------------------------------------------------------------------------
resource "aws_instance" "k3s" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.k3s.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.node.name
  key_name                    = var.key_name

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    aws_region     = var.aws_region
    secret_arn     = aws_secretsmanager_secret.kubeconfig.arn
    cluster_name   = var.name
    k3s_version    = var.k3s_version
    k3s_channel    = var.k3s_channel
    extra_tls_sans = var.extra_tls_sans
  })
  user_data_replace_on_change = true

  # IMDSv2 only; hop limit 1 keeps pods from reaching the instance role credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = var.name
  }

  # Don't replace the node every time Canonical publishes a new AMI.
  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [aws_iam_role_policy.publish_kubeconfig]
}


resource "terraform_data" "wait_for_k3s" {
  count = var.wait_for_ready ? 1 : 0

  triggers_replace = [aws_instance.k3s.id, aws_instance.k3s.public_ip]

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/wait-for-k3s.sh"

    environment = {
      PUBLIC_IP = aws_instance.k3s.public_ip
      REGION    = var.aws_region
      SECRET_ID = aws_secretsmanager_secret.kubeconfig.arn
      TIMEOUT   = tostring(var.wait_timeout_seconds)
      CHECK_API = tostring(var.allow_runner_ip)
    }
  }

  depends_on = [
    aws_vpc_security_group_ingress_rule.api,
    aws_iam_role_policy.publish_kubeconfig,
  ]
}