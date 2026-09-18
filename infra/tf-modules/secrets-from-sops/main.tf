data "sops_file" "this" {
  source_file = var.source_file
}

resource "aws_secretsmanager_secret" "this" {
  name = var.secret_name
  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = data.sops_file.this.raw
}