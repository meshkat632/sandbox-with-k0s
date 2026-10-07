output "public_ips" {
  description = "Ephemeral public IPs of the worker instances"
  value       = aws_instance.worker[*].public_ip
}

output "private_ips" {
  description = "Private IPs of the worker instances (the node addresses for talosctl -n)"
  value       = aws_instance.worker[*].private_ip
}
