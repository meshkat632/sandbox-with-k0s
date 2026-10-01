# One-time setup, run LOCALLY with admin AWS credentials (local state):
#   cd bootstrap-oidc
#   terraform init
#   terraform apply -var tfc_organization=<org> -var tfc_workspace=k3k-host-cluster
#
# Creates an OIDC trust between HCP Terraform and AWS plus an IAM role the
# workspace assumes, so no static AWS keys are stored in HCP Terraform.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "tfc_hostname" {
  type    = string
  default = "app.terraform.io"
}

variable "tfc_organization" {
  description = "Your HCP Terraform organization name."
  type        = string
}

variable "tfc_project" {
  description = "HCP Terraform project containing the workspace (\"*\" = any)."
  type        = string
  default     = "*"
}

variable "tfc_workspace" {
  type    = string
  default = "k3k-host-cluster"
}

variable "resource_prefix" {
  description = "Must match var.name in the main configuration."
  type        = string
  default     = "k3k-host"
}

variable "create_oidc_provider" {
  description = "Set false if app.terraform.io is already registered as an OIDC provider in this account."
  type        = bool
  default     = true
}

data "aws_caller_identity" "current" {}

data "tls_certificate" "tfc" {
  url = "https://${var.tfc_hostname}"
}

resource "aws_iam_openid_connect_provider" "tfc" {
  count = var.create_oidc_provider ? 1 : 0

  url             = data.tls_certificate.tfc.url
  client_id_list  = ["aws.workload.identity"]
  thumbprint_list = [data.tls_certificate.tfc.certificates[0].sha1_fingerprint]
}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  oidc_arn     = var.create_oidc_provider ? aws_iam_openid_connect_provider.tfc[0].arn : "arn:aws:iam::${local.account_id}:oidc-provider/${var.tfc_hostname}"
  name_pattern = "${var.resource_prefix}*"
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.tfc_hostname}:aud"
      values   = ["aws.workload.identity"]
    }

    condition {
      test     = "StringLike"
      variable = "${var.tfc_hostname}:sub"
      values   = ["organization:${var.tfc_organization}:project:${var.tfc_project}:workspace:${var.tfc_workspace}:run_phase:*"]
    }
  }
}

resource "aws_iam_role" "tfc" {
  name               = "${var.resource_prefix}-tfc-runner"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

data "aws_iam_policy_document" "permissions" {
  statement {
    sid       = "EC2"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  statement {
    sid     = "KubeconfigSecret"
    actions = ["secretsmanager:*"]
    resources = [
      "arn:aws:secretsmanager:*:${local.account_id}:secret:${local.name_pattern}",
    ]
  }

  statement {
    sid = "NodeRole"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.name_pattern}",
      "arn:aws:iam::${local.account_id}:instance-profile/${local.name_pattern}",
    ]
  }

  statement {
    sid       = "PassNodeRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.name_pattern}"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "tfc" {
  name   = "k3k-host-provisioning"
  role   = aws_iam_role.tfc.id
  policy = data.aws_iam_policy_document.permissions.json
}

output "tfc_workspace_env_vars" {
  description = "Set these as ENVIRONMENT variables in the HCP Terraform workspace."
  value = {
    TFC_AWS_PROVIDER_AUTH = "true"
    TFC_AWS_RUN_ROLE_ARN  = aws_iam_role.tfc.arn
  }
}
