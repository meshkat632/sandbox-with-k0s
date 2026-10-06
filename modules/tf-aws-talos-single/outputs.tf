output "public_ip" {
  description = "Ephemeral public IP of the control-plane instance"
  value       = aws_instance.talos.public_ip
}

output "instance_id" {
  value = aws_instance.talos.id
}

output "worker_public_ips" {
  description = "Ephemeral public IPs of the worker instances"
  value       = aws_instance.worker[*].public_ip
}

output "node_count" {
  description = "Control plane + workers"
  value       = 1 + var.worker_count
}

output "kubeconfig" {
  description = "Admin kubeconfig for the cluster"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "talosctl client config"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}