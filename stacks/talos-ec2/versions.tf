terraform {


  cloud {
    organization = "sandbox-v1"
    workspaces {
      name = "talos-ec2"
    }
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    http = {
      source = "hashicorp/http"
    }
    talos = {
      source = "siderolabs/talos"
    }
  }
}

# Region comes from cluster.yaml too
provider "aws" {
  region = local.region

  default_tags {
    tags = local.tags
  }
}
