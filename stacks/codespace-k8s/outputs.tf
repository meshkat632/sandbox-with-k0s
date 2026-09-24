output "namespaces" {
  description = "Namespaces managed by this stack."
  value       = sort([for ns in kubernetes_namespace_v1.this : ns.metadata[0].name])
}

output "cluster_endpoint" {
  description = "Kubernetes API server this stack talks to."
  value       = nonsensitive(local.kubeconfig.clusters[0].cluster.server) # the address only, not credentials
}

output "ingress_nginx" {
  description = "ingress-nginx release and the URL it serves on (ports 80/443 of the instance)."
  value = {
    namespace = helm_release.ingress_nginx.namespace
    version   = helm_release.ingress_nginx.version
    url       = "http://${local.public_host}"
  }
}

output "hello_url" {
  description = "HTTPS URL of the hello-world app."
  value       = "https://${local.hello_host}"
}
