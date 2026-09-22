output "instance_ids" {
  value = aws_instance.this[*].id
}

output "public_ips" {
  value = aws_instance.this[*].public_ip
}

output "public_dns" {
  value = aws_instance.this[*].public_dns
}

output "private_ips" {
  value = aws_instance.this[*].private_ip
}
