output "objects" {
  description = "Keys (Kind/name) of all deployed objects"
  value       = sort(keys(local.manifests))
}