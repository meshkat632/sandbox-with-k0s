terraform {
  required_version = ">= 1.4"
}

data "terraform_remote_state" "database" {
  backend = "local"
  config = {
    path = "${path.module}/../03-database/terraform.tfstate"
  }
}

data "terraform_remote_state" "iam" {
  backend = "local"
  config = {
    path = "${path.module}/../02-iam/terraform.tfstate"
  }
}

resource "terraform_data" "app" {
  input = {
    database = data.terraform_remote_state.database.outputs.endpoint
    role     = data.terraform_remote_state.iam.outputs.role
  }
}

output "app" {
  value = terraform_data.app.output
}
