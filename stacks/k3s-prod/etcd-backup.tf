# ---------------------------------------------------------------------------
# etcd snapshots to S3
#
# One private bucket per cluster (named after var.name). An SSM association runs
# scripts/configure-etcd-s3.sh on every server: it points K3s's scheduled etcd
# snapshots at the bucket and takes one snapshot straight away, so `apply` fails
# if a snapshot cannot reach S3. It re-runs when the script, settings or servers change.
# Logs: AWS console -> Systems Manager -> State Manager, or
#   aws ssm describe-association-executions --association-id <id>
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# --- Bucket ------------------------------------------------------------------
# No force_destroy: `terraform destroy` refuses to delete a bucket that still holds snapshots.
resource "aws_s3_bucket" "etcd_snapshots" {
  bucket = "${var.name}-etcd-snapshots-${data.aws_caller_identity.current.account_id}"

  tags = { Name = "${var.name}-etcd-snapshots" }
}

resource "aws_s3_bucket_public_access_block" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "etcd_snapshots" {
  bucket = aws_s3_bucket.etcd_snapshots.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- Servers may read and write their own cluster's bucket only ---------------
resource "aws_iam_role_policy" "k3s_etcd_snapshots" {
  name = "${var.name}-etcd-snapshots"
  role = aws_iam_role.k3s.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.etcd_snapshots.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.etcd_snapshots.arn}/*"
      },
    ]
  })
}

# --- Configure K3s on the servers --------------------------------------------
resource "aws_ssm_document" "etcd_s3" {
  name            = "${var.name}-etcd-s3"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Point K3s etcd snapshots at S3 and verify with a snapshot"
    parameters = {
      Bucket = {
        type           = "String"
        description    = "Snapshot bucket"
        allowedPattern = "^[a-z0-9.-]+$"
      }
      Region = {
        type           = "String"
        description    = "Bucket region"
        allowedPattern = "^[a-z0-9-]+$"
      }
      Folder = {
        type           = "String"
        description    = "Key prefix inside the bucket"
        allowedPattern = "^[A-Za-z0-9._-]+$"
      }
      Cron = {
        type           = "String"
        description    = "Snapshot schedule (cron)"
        allowedPattern = "^[0-9*/, -]+$"
      }
      Retention = {
        type           = "String"
        description    = "Scheduled snapshots to keep"
        allowedPattern = "^[0-9]+$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "configureEtcdS3"
      inputs = {
        timeoutSeconds = "1200"
        # SSM may run this with /bin/sh (dash), so write the bash script to the
        # node and run it with bash. It stays there for manual re-runs.
        runCommand = concat(
          ["cat > /usr/local/bin/configure-etcd-s3.sh <<'ETCD_S3_EOF'"],
          split("\n", trimspace(file("${path.module}/scripts/configure-etcd-s3.sh"))),
          [
            "ETCD_S3_EOF",
            "chmod 0755 /usr/local/bin/configure-etcd-s3.sh",
            "ETCD_S3_BUCKET='{{ Bucket }}' ETCD_S3_REGION='{{ Region }}' ETCD_S3_FOLDER='{{ Folder }}' ETCD_SNAPSHOT_CRON='{{ Cron }}' ETCD_SNAPSHOT_RETENTION='{{ Retention }}' bash /usr/local/bin/configure-etcd-s3.sh",
          ],
        )
      }
    }]
  })
}

resource "aws_ssm_association" "etcd_s3" {
  name             = aws_ssm_document.etcd_s3.name
  association_name = "${var.name}-etcd-s3"
  document_version = aws_ssm_document.etcd_s3.latest_version

  targets {
    key    = "InstanceIds"
    values = aws_instance.k3s_server[*].id
  }

  parameters = {
    Bucket    = aws_s3_bucket.etcd_snapshots.bucket
    Region    = var.aws_region
    Folder    = var.name
    Cron      = var.etcd_snapshot_schedule
    Retention = tostring(var.etcd_snapshot_retention)
  }

  # Block `terraform apply` until a snapshot has reached the bucket from every server.
  wait_for_success_timeout_seconds = 1200

  # Needs the bucket rights and the SSM rights on the instance role.
  depends_on = [
    aws_iam_role_policy.k3s_etcd_snapshots,
    aws_iam_role_policy_attachment.k3s_ssm,
    aws_s3_bucket_public_access_block.etcd_snapshots,
  ]
}
