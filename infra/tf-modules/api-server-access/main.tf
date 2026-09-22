resource "aws_vpc_security_group_ingress_rule" "api_server" {
  for_each = toset(var.cidr_blocks)

  security_group_id = var.security_group_id
  description       = "API server access from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = var.port
  to_port           = var.port
  cidr_ipv4         = each.value

  tags = var.tags
}
