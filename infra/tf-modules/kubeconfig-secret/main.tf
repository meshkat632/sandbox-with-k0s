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

# Reads back whatever the CURRENT version actually is (the resource above
# only ever reflects what IT wrote — the placeholder — since ignore_changes
# stops Terraform from tracking get_kubeconfig.sh's out-of-band updates).
# Data sources always refresh, so this surfaces the real kubeconfig once
# it's been pushed, without Terraform ever having generated it itself.
data "aws_secretsmanager_secret_version" "current" {
  secret_id  = aws_secretsmanager_secret.this.id
  depends_on = [aws_secretsmanager_secret_version.this]
}
