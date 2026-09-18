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