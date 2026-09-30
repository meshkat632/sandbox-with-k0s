terraform {
  required_version = ">= 1.8" # provider-defined functions

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.31" # manifest_decode_multi
    }
  }
}