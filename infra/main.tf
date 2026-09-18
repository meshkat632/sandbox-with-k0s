provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "k0stool"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}


# secrets.tf
data "sops_file" "tokens" {
  source_file = "${path.module}/secrets/tokens.secrets.yaml"
}

output "tokens_debug" {
  value     = data.sops_file.tokens.raw
  sensitive = true
}

resource "aws_secretsmanager_secret" "tokens" {
  name = "sandbox/tokens-test-v1"
}

resource "aws_secretsmanager_secret_version" "tokens" {
  secret_id     = aws_secretsmanager_secret.tokens.id
  secret_string = data.sops_file.tokens.raw
}

/*
resource "aws_secretsmanager_secret" "tokens" {
  for_each = data.sops_file.tokens.data
  name     = "app/${each.key}"
}

resource "aws_secretsmanager_secret_version" "tokens" {
  for_each      = data.sops_file.tokens.data
  secret_id     = aws_secretsmanager_secret.tokens[each.key].id
  secret_string = each.value
}
*/
