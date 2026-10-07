terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    http = {
      source = "hashicorp/http"
    }
    # Not in the hashicorp namespace, so every module that uses it must say so
    talos = {
      source = "siderolabs/talos"
    }
  }
}
