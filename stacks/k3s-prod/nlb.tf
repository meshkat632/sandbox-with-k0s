# ---------------------------------------------------------------------------
# Public NLB in front of the kube API (6443) on the server nodes
#
# Reachable only from var.allowed_cidrs; with an empty list nothing gets in.
# TCP passthrough: TLS still terminates on the K3s servers.
# ---------------------------------------------------------------------------
resource "aws_security_group" "api_nlb" {
  name   = "${var.name}-api-nlb"
  vpc_id = aws_vpc.this.id

  dynamic "ingress" {
    for_each = length(var.allowed_cidrs) > 0 ? [1] : []

    content {
      description = "kube API"
      from_port   = 6443
      to_port     = 6443
      protocol    = "tcp"
      cidr_blocks = var.allowed_cidrs
    }
  }

  egress {
    description = "kube API + health checks to the servers"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${var.name}-api-nlb" }
}

resource "aws_lb" "api" {
  name               = "${var.name}-api"
  load_balancer_type = "network"
  internal           = false
  subnets            = [for s in aws_subnet.public : s.id]
  security_groups    = [aws_security_group.api_nlb.id]

  enable_cross_zone_load_balancing = true

  tags = { Name = "${var.name}-api" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_lb_target_group" "api" {
  name     = "${var.name}-api"
  port     = 6443
  protocol = "TCP"
  vpc_id   = aws_vpc.this.id

  # K3s answers /ping without credentials (anonymous auth is off, so /readyz would 401)
  health_check {
    protocol            = "HTTPS"
    path                = "/ping"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${var.name}-api" }
}

resource "aws_lb_target_group_attachment" "api" {
  count = var.server_count

  target_group_arn = aws_lb_target_group.api.arn
  target_id        = aws_instance.k3s_server[count.index].id
  port             = 6443
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
