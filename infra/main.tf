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


/*

i need to make the follow as a callable module from tf-modules folder

*/

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


module "tokens_secret" {
  source      = "./tf-modules/secrets-from-sops"
  source_file = "${path.root}/secrets/tokens.secrets.yaml"
  secret_name = "sandbox/tokens-test-v2"

  expose_debug_output = true   # flip to false once verified

  tags = {
    Environment = "sandbox"
  }
}

output "tokens_secret_arn" {
  value = module.tokens_secret.secret_arn
}