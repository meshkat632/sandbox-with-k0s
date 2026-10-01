terraform {
  required_version = ">= 1.6.0"

  # HCP Terraform (app.terraform.io). Replace the organization and workspace
  # names with your own, or remove `organization` and set the
  # TF_CLOUD_ORGANIZATION environment variable instead.
  cloud {
    organization = "sandbox-v1"
    workspaces {
      name = "k3k-host-cluster"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }

  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Project   = var.name
        ManagedBy = "terraform"
      },
      var.tags,
    )
  }
}
