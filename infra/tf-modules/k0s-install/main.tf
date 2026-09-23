locals {
  script_b64 = filebase64(var.script_path)

  install_command = var.role == "controller" ? (
    "sudo python3 /tmp/install_k0s.py --role controller${var.enable_worker ? " --enable-worker" : ""}"
    ) : (
    "sudo python3 /tmp/install_k0s.py --role worker --controller-ip ${var.controller_ip} --token '${var.token}'"
  )
}

resource "aws_ssm_association" "this" {
  name             = "AWS-RunShellScript"
  association_name = "k0s-install-${var.instance_id}"

  targets {
    key    = "InstanceIds"
    values = [var.instance_id]
  }

  parameters = {
    commands = join("\n", [
      "echo ${local.script_b64} | base64 -d > /tmp/install_k0s.py",
      local.install_command,
    ])
  }

  # Without this, `apply` returns as soon as CreateAssociation succeeds —
  # it does not wait for the instance to boot, register with SSM, or for
  # the install command to actually finish. State Manager retries against
  # not-yet-manageable targets on its own schedule regardless; this just
  # makes Terraform block on that same retry loop until it reaches Success
  # (or fails the apply if it doesn't within the timeout).
  wait_for_success_timeout_seconds = var.wait_for_success_timeout_seconds

  lifecycle {
    precondition {
      condition     = var.role != "worker" || (var.controller_ip != null && var.token != null)
      error_message = "role = \"worker\" requires both controller_ip and token."
    }
  }
}
