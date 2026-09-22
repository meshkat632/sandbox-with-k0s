output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "internet_gateway_id" {
  value = aws_internet_gateway.this.id
}

output "route_table_id" {
  value = aws_route_table.public.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, in the same order as public_subnet_cidrs"
  value       = [for cidr in var.public_subnet_cidrs : aws_subnet.public[cidr].id]
}

output "public_subnet_azs" {
  description = "Availability zone of each public subnet, in the same order as public_subnet_cidrs"
  value       = [for cidr in var.public_subnet_cidrs : aws_subnet.public[cidr].availability_zone]
}

output "availability_zones" {
  value = data.aws_availability_zones.available.names
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "security_group_arn" {
  value = aws_security_group.this.arn
}
