variable "name" {
  type = string
}

output "label" {
  value = "example-${var.name}"
}
