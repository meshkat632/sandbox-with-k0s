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


# ---------------------------------------------------------------------------
# Tenant vcluster API exposure, multiplexed on the shared API NLB.
# Each k3k vcluster claims a NodePort; we add a listener + target group that
# forwards that port to the WORKER nodes. The host API (6443) above is untouched.
# ---------------------------------------------------------------------------
variable "vcluster_nodeports" {
  description = "vcluster name => NodePort exposed via the shared API NLB"
  type        = map(number)
  default = {
    "public-1" = 30444
  }
}

# One attachment per (vcluster, worker pool). NodePort is open on every node,
# so registering all worker ASGs makes any node a valid entry point.
locals {
  vc_asg_attachments = merge([
    for vc, port in var.vcluster_nodeports : {
      for pool, asg in aws_autoscaling_group.worker :
      "${vc}-${pool}" => { vc = vc, pool = pool }
    }
  ]...)
}
# NLB SG: let clients in on each tenant port...
resource "aws_security_group_rule" "api_nlb_vc_ingress" {
  for_each          = length(var.allowed_cidrs) > 0 ? var.vcluster_nodeports : {}
  type              = "ingress"
  description       = "vcluster ${each.key} API"
  from_port         = each.value
  to_port           = each.value
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidrs
  security_group_id = aws_security_group.api_nlb.id
}

# ...and let the NLB reach the workers' NodePort.
resource "aws_security_group_rule" "api_nlb_vc_egress" {
  for_each          = var.vcluster_nodeports
  type              = "egress"
  description       = "vcluster ${each.key} to workers"
  from_port         = each.value
  to_port           = each.value
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.api_nlb.id
}

# Worker SG: accept the NodePort traffic from the NLB SG.
resource "aws_security_group_rule" "worker_vc_from_nlb" {
  for_each                 = var.vcluster_nodeports
  type                     = "ingress"
  description              = "vcluster ${each.key} NodePort from API NLB"
  from_port                = each.value
  to_port                  = each.value
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.api_nlb.id
  security_group_id = aws_security_group.k3s.id   # was aws_security_group.k3s_workers.id
}

resource "aws_lb_target_group" "vc" {
  for_each = var.vcluster_nodeports
  name     = "${var.name}-${each.key}"   # must stay <= 32 chars
  port     = each.value
  protocol = "TCP"
  vpc_id   = aws_vpc.this.id

  # NodePort forwards to the vcluster's k3s apiserver, which answers /ping unauthenticated
  health_check {
    protocol            = "HTTPS"
    path                = "/ping"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  # Source becomes the NLB (not the client), so the worker SG rule above matches.
  preserve_client_ip = false

  tags = { Name = "${var.name}-${each.key}" }
}

resource "aws_autoscaling_attachment" "vc" {
  for_each               = local.vc_asg_attachments
  autoscaling_group_name = aws_autoscaling_group.worker[each.value.pool].name
  lb_target_group_arn    = aws_lb_target_group.vc[each.value.vc].arn
}

resource "aws_lb_listener" "vc" {
  for_each          = var.vcluster_nodeports
  load_balancer_arn = aws_lb.api.arn
  port              = each.value
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vc[each.key].arn
  }
}