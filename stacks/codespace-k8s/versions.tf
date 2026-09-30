terraform {
  required_version = ">= 1.8.0, < 2.0.0" # provider functions

  cloud {
    organization = "sandbox-v1"
    workspaces {
      name = "stacks-codespace-k8s"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}
