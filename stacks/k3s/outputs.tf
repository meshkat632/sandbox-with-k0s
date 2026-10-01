output "instance_id" {
  value = aws_instance.k3s.id
}

output "public_ip" {
  description = "Public IP (changes if the instance is stopped/started; the kubeconfig secret is refreshed automatically on boot)."
  value       = aws_instance.k3s.public_ip
}

output "api_server_url" {
  value = "https://${aws_instance.k3s.public_ip}:6443"
}

output "kubeconfig_secret_arn" {
  value = aws_secretsmanager_secret.kubeconfig.arn
}

output "get_kubeconfig_command" {
  description = "Run locally to fetch the kubeconfig (available ~2-4 minutes after apply)."
  value       = "aws secretsmanager get-secret-value --region ${var.aws_region} --secret-id ${aws_secretsmanager_secret.kubeconfig.name} --query SecretString --output text > ${var.name}-kubeconfig.yaml"
}

output "ssm_session_command" {
  value = var.enable_ssm ? "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.k3s.id}" : null
}

output "whitelisted_cidrs" {
  value = local.api_cidrs
}