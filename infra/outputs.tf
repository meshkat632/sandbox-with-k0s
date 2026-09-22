output "vpc_id" {
  description = "ID of the created VPC."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, one per availability zone."
  value       = module.network.public_subnet_ids
}

output "internet_gateway_id" {
  description = "ID of the internet gateway attached to the VPC."
  value       = module.network.internet_gateway_id
}

output "route_table_id" {
  description = "ID of the shared public route table."
  value       = module.network.route_table_id
}

output "security_group_id" {
  description = "ID of the network security group (SSH access)."
  value       = module.network.security_group_id
}

output "launch_template_id" {
  description = "ID of the EC2 launch template."
  value       = module.launch_template.id
}

output "launch_template_latest_version" {
  description = "Latest version of the EC2 launch template."
  value       = module.launch_template.latest_version
}

output "k0s_node_ids" {
  description = "IDs of the k0s node instances."
  value       = module.k0s_nodes.instance_ids
}

output "k0s_node_public_ips" {
  description = "Public IPs of the k0s node instances, in index order."
  value       = module.k0s_nodes.public_ips
}

output "k0s_node_public_dns" {
  description = "Public DNS names of the k0s node instances, in index order."
  value       = module.k0s_nodes.public_dns
}

output "k0s_node_private_ips" {
  description = "Private IPs of the k0s node instances, in index order (cluster-internal traffic)."
  value       = module.k0s_nodes.private_ips
}

output "ssm_instance_profile_name" {
  description = "Name of the IAM instance profile giving nodes SSM access."
  value       = module.ssm_profile.instance_profile_name
}
