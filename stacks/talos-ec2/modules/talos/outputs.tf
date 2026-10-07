output "public_ip" {
  value = aws_instance.talos.public_ip
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
