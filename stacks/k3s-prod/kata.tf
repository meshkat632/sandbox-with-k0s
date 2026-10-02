# ---------------------------------------------------------------------------
# Kata Containers on the worker pools
#
# Pods that set `runtimeClassName: kata` run inside a lightweight VM instead of
# sharing the node's kernel. That needs KVM on the node, which on EC2 means an
# instance type with nested virtualization (C8i/M8i/R8i) or a bare-metal one;
# workers.tf turns nested virtualization on for pools with kata = true.
#
# An SSM association runs scripts/install-kata.sh on every server, which installs
# the upstream kata-deploy Helm chart through K3s's Helm controller. It re-runs
# when the script, version or servers change. Nothing is installed while no pool
# has kata = true.
# Logs: AWS console -> Systems Manager -> State Manager, or
#   aws ssm describe-association-executions --association-id <id>
# ---------------------------------------------------------------------------
locals {
  kata_enabled = anytrue([for _, p in var.node_pools : p.kata])
}

resource "aws_ssm_document" "kata" {
  count = local.kata_enabled ? 1 : 0

  name            = "${var.name}-kata"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install Kata Containers (kata-deploy Helm chart) on a K3s cluster"
    parameters = {
      Version = {
        type           = "String"
        description    = "kata-deploy chart version"
        allowedPattern = "^[0-9A-Za-z.+-]+$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "installKata"
      inputs = {
        timeoutSeconds = "2400"
        # SSM may run this with /bin/sh (dash), so write the bash script to the
        # node and run it with bash. It stays there for manual re-runs.
        runCommand = concat(
          ["cat > /usr/local/bin/install-kata.sh <<'KATA_INSTALL_EOF'"],
          split("\n", trimspace(file("${path.module}/scripts/install-kata.sh"))),
          [
            "KATA_INSTALL_EOF",
            "chmod 0755 /usr/local/bin/install-kata.sh",
            "KATA_VERSION='{{ Version }}' bash /usr/local/bin/install-kata.sh",
          ],
        )
      }
    }]
  })
}

resource "aws_ssm_association" "kata" {
  count = local.kata_enabled ? 1 : 0

  name             = aws_ssm_document.kata[0].name
  association_name = "${var.name}-kata"
  document_version = aws_ssm_document.kata[0].latest_version

  targets {
    key    = "InstanceIds"
    values = aws_instance.k3s_server[*].id
  }

  parameters = {
    Version = var.kata_version
  }

  # Block `terraform apply` until the chart is installed.
  wait_for_success_timeout_seconds = 2400

  depends_on = [aws_iam_role_policy_attachment.k3s_ssm]
}
