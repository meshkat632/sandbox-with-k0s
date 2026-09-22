provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "k0stool"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

resource "random_id" "suffix" {
  count       = var.name_suffix == null ? 1 : 0
  byte_length = 3
}

locals {
  # Explicit var.name_suffix (including "") always wins, so a state with
  # real resources can pin its existing (possibly suffix-less) names.
  # Otherwise fall back to a random one, generated once and then stable
  # for the lifetime of this state — making a brand-new state/workspace
  # collision-free against any other, with no manual coordination.
  computed_suffix = var.name_suffix != null ? var.name_suffix : random_id.suffix[0].hex
  name_prefix     = local.computed_suffix == "" ? "k0stool-${var.environment}" : "k0stool-${var.environment}-${local.computed_suffix}"
  key_name        = local.computed_suffix == "" ? var.key_name : "${var.key_name}-${local.computed_suffix}"
  secret_name     = local.computed_suffix == "" ? var.tokens_secret_name : "${var.tokens_secret_name}-${local.computed_suffix}"
}

resource "aws_key_pair" "this" {
  key_name   = local.key_name
  public_key = trimspace(var.public_key != null ? var.public_key : file(pathexpand(var.public_key_path)))
}

module "tokens_secret" {
  source      = "./tf-modules/secrets-from-sops"
  source_file = "${path.root}/secrets/tokens.secrets.yaml"
  secret_name = local.secret_name

  expose_debug_output = true # flip to false once verified

  tags = {
    Environment = "sandbox"
  }
}

module "network" {
  source = "./tf-modules/network"

  name                = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
  ssh_cidr            = var.ssh_cidr
  kube_api_cidrs      = var.kube_api_cidrs
}

module "ssm_profile" {
  source = "./tf-modules/ssm-instance-profile"

  name = local.name_prefix

  extra_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ]
}

module "node_bootstrap" {
  source = "./tf-modules/node-bootstrap"
}

module "launch_template" {
  source = "./tf-modules/launch-template"

  name                      = local.name_prefix
  instance_type             = var.instance_type
  key_name                  = aws_key_pair.this.key_name
  security_group_ids        = [module.network.security_group_id]
  iam_instance_profile_name = module.ssm_profile.instance_profile_name
  user_data                 = module.node_bootstrap.user_data
}

module "k0s_nodes" {
  source = "./tf-modules/instances"

  name               = "${local.name_prefix}-node"
  launch_template_id = module.launch_template.id
  subnet_ids         = module.network.public_subnet_ids
  instance_count     = var.instance_count
}

output "tokens_secret_arn" {
  value = module.tokens_secret.secret_arn
}
