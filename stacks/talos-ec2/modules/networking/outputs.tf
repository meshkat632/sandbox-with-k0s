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

output "load_balancer_ip" {
  description = "Fixed public IP of the load balancer (null without one)"
  value       = var.load_balancer_enabled ? aws_eip.lb[0].public_ip : null
}

output "load_balancer_security_group_id" {
  value = var.load_balancer_enabled ? aws_security_group.lb[0].id : null
}

output "target_group_arns" {
  description = "Target groups by name: api (6443), http (80), https (443)"
  value       = { for name, tg in aws_lb_target_group.this : name => tg.arn }
}
