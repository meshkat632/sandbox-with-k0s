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
  description = "Talos cluster nodes"
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

  # Without a load balancer, HTTP/HTTPS goes straight to the node
  dynamic "ingress" {
    for_each = !var.load_balancer_enabled && length(var.http_ingress_cidrs) > 0 ? [80, 443] : []
    content {
      description = "HTTP/HTTPS to an ingress controller on the node"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.http_ingress_cidrs
    }
  }

  # With one, it arrives from the load balancer
  dynamic "ingress" {
    for_each = var.load_balancer_enabled ? local.lb_ports : []
    content {
      description     = "From the load balancer"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [aws_security_group.lb[0].id]
    }
  }

  ingress {
    description = "Node to node (control plane, workers, pod network)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
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

# ---------------------------------------------------------------------------
# Network Load Balancer (optional): one fixed public IP in front of all
# control plane nodes for the Kubernetes API, and in front of every node for
# the ingress controller.
# ---------------------------------------------------------------------------
locals {
  lb_ports = [6443, 80, 443]

  lb_target_groups = {
    api   = 6443
    http  = 80
    https = 443
  }
}

# The rules of this group are separate resources, because the talos and
# workers modules add one per node: inline rules would fight with them.
resource "aws_security_group" "lb" {
  count = var.load_balancer_enabled ? 1 : 0

  name        = "${var.cluster_name}-lb-sg"
  description = "Talos cluster load balancer"
  vpc_id      = data.aws_vpc.default.id

  tags = merge(var.tags, { Name = "${var.cluster_name}-lb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "lb_api" {
  count = var.load_balancer_enabled ? 1 : 0

  security_group_id = aws_security_group.lb[0].id
  description       = "Kubernetes API"
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_ipv4         = local.allowed_cidr
}

resource "aws_vpc_security_group_ingress_rule" "lb_http" {
  for_each = var.load_balancer_enabled ? {
    for pair in setproduct([80, 443], var.http_ingress_cidrs) : "${pair[0]}-${pair[1]}" => pair
  } : {}

  security_group_id = aws_security_group.lb[0].id
  description       = "HTTP/HTTPS to the ingress controller"
  ip_protocol       = "tcp"
  from_port         = each.value[0]
  to_port           = each.value[0]
  cidr_ipv4         = each.value[1]
}

resource "aws_vpc_security_group_egress_rule" "lb" {
  count = var.load_balancer_enabled ? 1 : 0

  security_group_id = aws_security_group.lb[0].id
  description       = "To the nodes"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Fixed IP: the API endpoint and the sslip.io host names are built from it
resource "aws_eip" "lb" {
  count = var.load_balancer_enabled ? 1 : 0

  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.cluster_name}-lb" })
}

# One subnet, the one the nodes are in: a single availability zone
resource "aws_lb" "this" {
  count = var.load_balancer_enabled ? 1 : 0

  name               = "${var.cluster_name}-lb"
  load_balancer_type = "network"
  internal           = false
  security_groups    = [aws_security_group.lb[0].id]

  subnet_mapping {
    subnet_id     = data.aws_subnets.default.ids[0]
    allocation_id = aws_eip.lb[0].id
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-lb" })
}

resource "aws_lb_target_group" "this" {
  for_each = var.load_balancer_enabled ? local.lb_target_groups : {}

  name     = "${var.cluster_name}-${each.key}"
  port     = each.value
  protocol = "TCP"
  vpc_id   = data.aws_vpc.default.id

  # Off: with the client address preserved, a node that reaches the load
  # balancer and is sent back to itself never gets an answer. The nodes do
  # that for the API, and cert-manager does it to check HTTP-01 challenges.
  preserve_client_ip = false

  # TCP check: the API server refuses anonymous requests to /readyz.
  # Fastest setting: a failed node still gets traffic for about 10 seconds.
  health_check {
    protocol            = "TCP"
    interval            = 5
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-${each.key}" })
}

resource "aws_lb_listener" "this" {
  for_each = var.load_balancer_enabled ? local.lb_target_groups : {}

  load_balancer_arn = aws_lb.this[0].arn
  port              = each.value
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }
}
