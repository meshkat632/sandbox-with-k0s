terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    http = {
      source = "hashicorp/http"
    }
    local = {
      source = "hashicorp/local"
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
