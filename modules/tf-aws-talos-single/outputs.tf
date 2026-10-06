output "public_ip" {
  description = "Ephemeral public IP of the instance"
  value       = aws_instance.talos.public_ip
}

output "instance_id" {
  value = aws_instance.talos.id
}

output "kubeconfig" {
  description = "Admin kubeconfig for the single-node cluster"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "talosctl client config"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}