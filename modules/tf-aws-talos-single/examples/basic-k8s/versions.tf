terraform {
  required_version = ">= 1.6.0"

  # HCP Terraform, state only: the workspace must use local execution, since
  # HCP runners can't reach the cluster's API.
  cloud {
    organization = "sandbox-v1"
    workspaces {
      name = "talos-single-test-k8s"
    }
  }

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}
