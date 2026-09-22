locals {
  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    packages = var.packages
  })
}
