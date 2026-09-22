output "user_data" {
  description = "Rendered bash user-data script: apt-get update, then install var.packages"
  value       = local.user_data
}
