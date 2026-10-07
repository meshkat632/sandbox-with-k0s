output "public_ip" {
  value = module.talos.public_ip
}

output "allowed_cidr" {
  description = "Your IP, the only source allowed to reach the Talos/Kubernetes APIs"
  value       = module.networking.allowed_cidr
}

output "kubeconfig" {
  value     = module.talos.kubeconfig
  sensitive = true
}

output "talosconfig" {
  value     = module.talos.talosconfig
  sensitive = true
}

output "talosconfig_parameter" {
  description = "SSM parameter holding the Talos client config (used by make kubeconfig)"
  value       = module.talos.talosconfig_parameter
}
