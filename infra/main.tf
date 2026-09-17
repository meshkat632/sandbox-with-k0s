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

resource "aws_key_pair" "k0stool" {
  key_name   = var.key_name
  public_key = trimspace(var.public_key)
}