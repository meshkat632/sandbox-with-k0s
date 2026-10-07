output "api_endpoint" {
  description = "Kubernetes API URL: the load balancer if there is one, else the node"
  value       = module.talos.cluster_endpoint
}

output "load_balancer_ip" {
  description = "Fixed public IP for the API and the ingress (null without a load balancer)"
  value       = module.networking.load_balancer_ip
}

output "control_plane_public_ips" {
  description = "Ephemeral public IPs of the control plane nodes (Talos API endpoints)"
  value       = module.talos.public_ips
}

output "control_plane_private_ips" {
  description = "Node addresses of the control plane for talosctl -n"
  value       = module.talos.private_ips
}

output "worker_public_ips" {
  value = module.workers.public_ips
}

output "worker_private_ips" {
  description = "Node addresses of the workers for talosctl -n"
  value       = module.workers.private_ips
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
