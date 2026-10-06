# Each stack keeps its own state. Here that is a local file per folder; with a
# remote backend, give every stack its own key.
terraform {
  required_version = ">= 1.4"
}

module "label" {
  source = "../_modules/label"
  name   = "network"
}

resource "terraform_data" "vpc" {
  input = { name = module.label.label, cidr = "10.0.0.0/16" }
}

output "vpc" {
  value = terraform_data.vpc.output
}
