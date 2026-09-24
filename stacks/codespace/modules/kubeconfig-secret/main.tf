resource "aws_secretsmanager_secret" "this" {
  name                    = var.secret_name
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags
}

# The real kubeconfig is only known once k0s is running on the instance,
# which Terraform has no visibility into. This placeholder just guarantees the
# secret has a fetchable version from the moment it's created; the instance
# overwrites it with the real content (PutSecretValue at the end of k0s.sh),
# and ignore_changes keeps Terraform from ever reverting that back.
resource "aws_secretsmanager_secret_version" "this" {
  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = "not yet populated — the instance publishes the kubeconfig once k0s is ready"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Reads back whatever the CURRENT version actually is (the resource above
# only ever reflects what IT wrote — the placeholder — since ignore_changes
# stops Terraform from tracking the instance's out-of-band updates).
# Data sources always refresh, so this surfaces the real kubeconfig once
# it's been pushed, without Terraform ever having generated it itself.
data "aws_secretsmanager_secret_version" "current" {
  secret_id  = aws_secretsmanager_secret.this.id
  depends_on = [aws_secretsmanager_secret_version.this]
}
