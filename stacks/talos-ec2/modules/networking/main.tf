# ---------------------------------------------------------------------------
# Caller's public IP - only this /32 may reach the Talos and Kubernetes APIs
# ---------------------------------------------------------------------------
data "http" "myip" {
  url = "https://checkip.amazonaws.com/"
}

locals {
  allowed_cidr = "${chomp(data.http.myip.response_body)}/32"
}

# ---------------------------------------------------------------------------
# Default VPC + a public subnet in it
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

# ---------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------
resource "aws_security_group" "talos" {
  name        = "${var.cluster_name}-sg"
  description = "Single-node Talos cluster"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Talos API (talosctl / TF provider)"
    from_port   = 50000
    to_port     = 50000
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  dynamic "ingress" {
    for_each = length(var.http_ingress_cidrs) > 0 ? [80, 443] : []
    content {
      description = "HTTP/HTTPS to an ingress controller on the node"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.http_ingress_cidrs
    }
  }

  egress {
    description = "All outbound (pull images, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-sg" })
}
