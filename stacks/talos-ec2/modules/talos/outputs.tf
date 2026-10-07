output "public_ips" {
  description = "Ephemeral public IPs of the control plane nodes (Talos API endpoints)"
  value       = aws_instance.talos[*].public_ip
}

output "private_ips" {
  description = "Node addresses of the control plane for talosctl -n"
  value       = aws_instance.talos[*].private_ip
}

output "cluster_endpoint" {
  description = "Kubernetes API URL in the kubeconfig"
  value       = local.cluster_endpoint
}

# Workers join through the load balancer. Without one they use the private IP
# of the control plane node: its public IP is not open to them.
output "worker_endpoint" {
  value = var.load_balancer_enabled ? local.cluster_endpoint : "https://${aws_instance.talos[0].private_ip}:6443"
}

# For the workers module: the same cluster secrets and Talos API client
output "machine_secrets" {
  value     = talos_machine_secrets.this.machine_secrets
  sensitive = true
}

output "client_configuration" {
  value     = talos_machine_secrets.this.client_configuration
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "talosconfig_parameter" {
  value = aws_ssm_parameter.talosconfig.name
}
