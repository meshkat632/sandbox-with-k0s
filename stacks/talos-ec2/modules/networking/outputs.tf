output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "subnet_id" {
  description = "Public subnet the nodes are placed in"
  value       = data.aws_subnets.default.ids[0]
}

output "security_group_id" {
  value = aws_security_group.talos.id
}

output "allowed_cidr" {
  description = "The CIDR that was actually allowed (resolved from your IP if not given)"
  value       = local.allowed_cidr
}
