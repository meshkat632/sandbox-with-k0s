output "namespaces" {
  description = "Namespaces managed by this stack."
  value       = sort([for ns in kubernetes_namespace_v1.this : ns.metadata[0].name])
}

output "cluster_endpoint" {
  description = "Kubernetes API server this stack talks to."
  value       = nonsensitive(local.kubeconfig.clusters[0].cluster.server) # the address only, not credentials
}
