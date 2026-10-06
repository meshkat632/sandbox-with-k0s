terraform {
  required_version = ">= 1.4"
}

# Read another stack's outputs from its state.
data "terraform_remote_state" "network" {
  backend = "local"
  config = {
    path = "${path.module}/../01-network/terraform.tfstate"
  }
}

resource "terraform_data" "database" {
  input = { vpc = data.terraform_remote_state.network.outputs.vpc.name }
}

output "endpoint" {
  value = "db.${terraform_data.database.output.vpc}.internal"
}
