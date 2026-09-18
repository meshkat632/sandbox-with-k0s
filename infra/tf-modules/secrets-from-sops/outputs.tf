output "secret_arn" {
  value = aws_secretsmanager_secret.this.arn
}

output "secret_id" {
  value = aws_secretsmanager_secret.this.id
}

output "debug_raw" {
  value     = var.expose_debug_output ? data.sops_file.this.raw : null
  sensitive = true
}