data "aws_iam_policy_document" "k3s_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "k3s" {
  name               = "${var.name}-k3s"
  assume_role_policy = data.aws_iam_policy_document.k3s_assume.json
}

# Minimal: lets k3s tag instances/EIPs (cloud provider) + S3 snapshot option
resource "aws_iam_role_policy" "k3s" {
  name = "${var.name}-k3s"
  role = aws_iam_role.k3s.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:Describe*",
        "ec2:AttachVolume", "ec2:CreateVolume", "ec2:DeleteVolume",
        "ec2:DetachVolume", "ec2:ModifyVolume",
        "ec2:CreateTags", "ec2:DeleteTags",
        "ec2:AssignPrivateIpAddresses",
        "elasticloadbalancing:Describe*"
      ]
      Resource = "*"
    }]
  })
}

# Session Manager access (the nodes have no public IPs and no SSH path)
resource "aws_iam_role_policy_attachment" "k3s_ssm" {
  role       = aws_iam_role.k3s.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "k3s" {
  name = "${var.name}-k3s"
  role = aws_iam_role.k3s.name
}
