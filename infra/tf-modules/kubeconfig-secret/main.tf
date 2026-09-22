resource "aws_secretsmanager_secret" "this" {
  name                    = var.secret_name
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags
}

# The real kubeconfig is only known after the controller is manually
# bootstrapped (scripts/install_k0s.py), which Terraform has no visibility
# into. This placeholder just guarantees the secret has a fetchable version
# from the moment it's created; scripts/get_kubeconfig.sh overwrites it with
# the real content via `aws secretsmanager put-secret-value`, and
# ignore_changes keeps Terraform from ever reverting that back.
resource "aws_secretsmanager_secret_version" "this" {
  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = "not yet populated — run scripts/get_kubeconfig.sh after bootstrapping the controller"

  lifecycle {
    ignore_changes = [secret_string]
  }
}
