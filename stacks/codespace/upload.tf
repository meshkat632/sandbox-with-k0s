# =============================================================================
# Upload: mirror var.upload_dir to var.upload_destination on the instance
#
# The files travel inside an SSM command document (base64), and an SSM
# association runs it on the instance. Everything is AWS API calls, so it
# works from Terraform Cloud, and editing the files updates the document and
# re-runs the association instead of replacing the instance (as user_data
# would). The association also runs on a replacement instance.
#
# SSM limits a document to 64 KB, so this suits scripts and small config
# files (roughly 45 KB in total); the precondition below enforces it.
# =============================================================================

locals {
  upload_root = "${path.module}/${var.upload_dir}"

  # Relative paths, hidden files and directories excluded
  upload_files = sort([
    for f in fileset(local.upload_root, "**") : f
    if !anytrue([for part in split("/", f) : startswith(part, ".")])
  ])

  upload_new = "${var.upload_destination}.new"
  upload_old = "${var.upload_destination}.old"

  # Written to a staging directory and swapped in, so the destination never
  # holds a partial upload and files removed from upload_dir disappear.
  upload_commands = concat(
    [
      "#!/bin/bash", # Run Command uses /bin/sh (dash) without a shebang
      "set -euo pipefail",
      "rm -rf '${local.upload_new}' '${local.upload_old}'",
      "install -d -m 755 '${local.upload_new}'",
    ],
    flatten([for f in local.upload_files : [
      "install -d -m 755 \"$(dirname '${local.upload_new}/${f}')\"",
      "echo '${filebase64("${local.upload_root}/${f}")}' | base64 -d > '${local.upload_new}/${f}'",
      "chmod 755 '${local.upload_new}/${f}'",
    ]]),
    [
      "chown -R root:root '${local.upload_new}'",
      "install -d -m 755 \"$(dirname '${var.upload_destination}')\"",
      "if [ -e '${var.upload_destination}' ]; then mv '${var.upload_destination}' '${local.upload_old}'; fi",
      "mv '${local.upload_new}' '${var.upload_destination}'",
      "rm -rf '${local.upload_old}'",
      "echo 'uploaded ${length(local.upload_files)} file(s) to ${var.upload_destination}'",
    ],
  )

  upload_document = jsonencode({
    schemaVersion = "2.2"
    description   = "Mirror ${var.upload_dir}/ from the ${local.name} Terraform stack to ${var.upload_destination}"
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "upload"
      inputs = {
        runCommand     = local.upload_commands
        timeoutSeconds = "120"
      }
    }]
  })
}

resource "aws_ssm_document" "upload" {
  count = length(local.upload_files) > 0 ? 1 : 0

  name            = "${local.name}-upload"
  document_type   = "Command"
  document_format = "JSON"
  content         = local.upload_document

  lifecycle {
    precondition {
      condition     = length(local.upload_document) <= 64000
      error_message = "${var.upload_dir}/ is too large for an SSM document (${length(local.upload_document)} of 64000 bytes after encoding); keep it to scripts and small files."
    }

    precondition {
      condition     = alltrue([for f in local.upload_files : can(regex("^[A-Za-z0-9._/-]+$", f))])
      error_message = "File names in ${var.upload_dir}/ may only contain letters, digits and ._-/ (they are used in a shell script)."
    }
  }
}

resource "aws_ssm_association" "upload" {
  count = length(local.upload_files) > 0 ? 1 : 0

  association_name = "${local.name}-upload"
  name             = aws_ssm_document.upload[0].name
  document_version = aws_ssm_document.upload[0].latest_version

  targets {
    key    = "InstanceIds"
    values = [aws_instance.this.id]
  }

  # Fail the apply if the upload fails, rather than only showing it in SSM.
  # The SSM agent must be online: the instance has to be running.
  wait_for_success_timeout_seconds = 600
}
