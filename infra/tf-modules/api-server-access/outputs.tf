output "rule_ids" {
  description = "Security group rule IDs, keyed by CIDR block"
  value       = { for cidr, rule in aws_vpc_security_group_ingress_rule.api_server : cidr => rule.security_group_rule_id }
}
