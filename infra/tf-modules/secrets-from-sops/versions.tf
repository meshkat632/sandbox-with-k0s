terraform {
  required_providers {
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}