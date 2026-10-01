# ---------------------------------------------------------------------------
# Install the K3k controller on the node via AWS SSM (Run Command / State Manager).
#
# Terraform creates an SSM document containing scripts/install-k3k.sh and an
# association that runs it on the instance. `apply` waits for it to succeed.
# It re-runs automatically when the script, chart version or instance changes.
# Logs: AWS console -> Systems Manager -> State Manager, or
#   aws ssm describe-association-executions --association-id <id>
# ---------------------------------------------------------------------------
resource "aws_ssm_document" "install_k3k" {
  count = var.install_k3k ? 1 : 0

  name            = "${var.name}-install-k3k"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install or upgrade the K3k controller with Helm on a K3s server"
    parameters = {
      ChartVersion = {
        type           = "String"
        description    = "k3k Helm chart version"
        default        = var.k3k_chart_version
        allowedPattern = "^[0-9A-Za-z.+-]+$"
      }
      Namespace = {
        type           = "String"
        description    = "Namespace for the k3k controller"
        default        = var.k3k_namespace
        allowedPattern = "^[a-z0-9-]+$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "installK3k"
      inputs = {
        timeoutSeconds = "1200"
        # SSM may run this with /bin/sh (dash), so write the bash script to the
        # node and run it with bash. It stays there for manual re-runs.
        runCommand = concat(
          ["cat > /usr/local/bin/install-k3k.sh <<'K3K_INSTALL_EOF'"],
          split("\n", trimspace(file("${path.module}/scripts/install-k3k.sh"))),
          [
            "K3K_INSTALL_EOF",
            "chmod 0755 /usr/local/bin/install-k3k.sh",
            "K3K_CHART_VERSION='{{ ChartVersion }}' K3K_NAMESPACE='{{ Namespace }}' bash /usr/local/bin/install-k3k.sh",
          ],
        )
      }
    }]
  })
}

resource "aws_ssm_association" "install_k3k" {
  count = var.install_k3k ? 1 : 0

  name             = aws_ssm_document.install_k3k[0].name
  association_name = "${var.name}-install-k3k"
  document_version = aws_ssm_document.install_k3k[0].latest_version

  targets {
    key    = "InstanceIds"
    values = [aws_instance.k3s.id]
  }

  parameters = {
    ChartVersion = var.k3k_chart_version
    Namespace    = var.k3k_namespace
  }

  # Block `terraform apply` until the install has succeeded on the instance.
  wait_for_success_timeout_seconds = 1200

  lifecycle {
    precondition {
      condition     = var.enable_ssm
      error_message = "install_k3k needs enable_ssm = true (the instance must be managed by SSM)."
    }
  }

  # Run only after K3s is up (when the wait step is enabled) and SSM rights are attached.
  depends_on = [
    terraform_data.wait_for_k3s,
    aws_iam_role_policy_attachment.ssm,
  ]
}