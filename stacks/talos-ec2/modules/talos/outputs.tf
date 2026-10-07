output "public_ip" {
  value = aws_instance.talos.public_ip
}

output "private_ip" {
  description = "Workers join the cluster through this address"
  value       = aws_instance.talos.private_ip
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
