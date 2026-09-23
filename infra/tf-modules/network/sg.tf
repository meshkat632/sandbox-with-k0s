resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "Allow SSH from the configured CIDR, all outbound traffic."
  vpc_id      = aws_vpc.this.id

  # No inline ingress/egress blocks here on purpose: an aws_security_group
  # with any inline rule block treats that block as the complete,
  # authoritative rule set and reconciles away anything else it finds on
  # the group — including rules added by unrelated resources/modules, such
  # as tf-modules/api-server-access's aws_vpc_security_group_ingress_rule
  # entries. Managing every rule as its own resource below avoids that.
  tags = merge({ Name = "${var.name}-sg" }, var.tags)
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.this.id
  description       = "SSH"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.ssh_cidr
}

resource "aws_vpc_security_group_ingress_rule" "k0s_internal" {
  for_each = toset(["6443", "8132", "8133"])

  security_group_id = aws_security_group.this.id
  description       = "k0s cluster internal (API, konnectivity)"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
