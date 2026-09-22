output "secret_arn" {
  value = aws_secretsmanager_secret.this.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.this.name
}

output "kubeconfig" {
  description = "Current content of the secret — the placeholder until scripts/get_kubeconfig.sh pushes the real kubeconfig"
  value       = data.aws_secretsmanager_secret_version.current.secret_string
  sensitive   = true
}
