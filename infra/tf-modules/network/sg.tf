resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "Allow SSH from the configured CIDR, all outbound traffic."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  dynamic "ingress" {
    for_each = [6443, 8132, 8133]

    content {
      description = "k0s cluster internal (API, konnectivity)"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  dynamic "ingress" {
    for_each = length(var.kube_api_cidrs) > 0 ? [1] : []

    content {
      description = "Kubernetes API from outside the VPC"
      from_port   = 6443
      to_port     = 6443
      protocol    = "tcp"
      cidr_blocks = var.kube_api_cidrs
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = "${var.name}-sg" }, var.tags)
}
