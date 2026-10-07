output "public_ip" {
  value = module.talos.public_ip
}

output "allowed_cidr" {
  description = "Your IP, the only source allowed to reach the Talos/Kubernetes APIs"
  value       = module.networking.allowed_cidr
}

output "kubeconfig_path" {
  description = "Where the admin kubeconfig is written"
  value       = local_sensitive_file.kubeconfig.filename
}

output "kubeconfig" {
  value     = module.talos.kubeconfig
  sensitive = true
}

output "talosconfig" {
  value     = module.talos.talosconfig
  sensitive = true
}
