output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "AZ => public subnet id (NLB, NAT)."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "private_subnet_ids" {
  description = "AZ => private subnet id (cluster nodes)."
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "nat_public_ip" {
  description = "Outbound IP of all private nodes (useful for allowlists elsewhere)."
  value       = aws_eip.nat.public_ip
}

output "api_endpoint" {
  description = "Kube API behind the public NLB (reachable from allowed_cidrs only)."
  value       = "https://${aws_lb.api.dns_name}:6443"
}
