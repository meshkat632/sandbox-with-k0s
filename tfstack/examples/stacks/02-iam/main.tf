terraform {
  required_version = ">= 1.4"
}

resource "terraform_data" "role" {
  input = "example-app-role"
}

output "role" {
  value = terraform_data.role.output
}
