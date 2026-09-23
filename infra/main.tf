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
  computed_suffix        = var.name_suffix != null ? var.name_suffix : random_id.suffix[0].hex
  name_prefix            = local.computed_suffix == "" ? "k0stool-${var.environment}" : "k0stool-${var.environment}-${local.computed_suffix}"
  key_name               = local.computed_suffix == "" ? var.key_name : "${var.key_name}-${local.computed_suffix}"
  secret_name            = local.computed_suffix == "" ? var.tokens_secret_name : "${var.tokens_secret_name}-${local.computed_suffix}"
  kubeconfig_secret_name = local.computed_suffix == "" ? var.kubeconfig_secret_name : "${var.kubeconfig_secret_name}-${local.computed_suffix}"
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
}

module "api_server_access" {
  source = "./tf-modules/api-server-access"

  security_group_id = module.network.security_group_id
  cidr_blocks       = var.kube_api_cidrs
}

module "kubeconfig_secret" {
  source = "./tf-modules/kubeconfig-secret"

  secret_name = local.kubeconfig_secret_name

  tags = {
    Environment = "sandbox"
  }
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

module "k0s_controller_install" {
  source = "./tf-modules/k0s-install"

  instance_id   = module.k0s_nodes.instance_ids[0]
  script_path   = "${path.root}/scripts/install_k0s.py"
  role          = "controller"
  enable_worker = var.controller_enable_worker
}

output "tokens_secret_arn" {
  value = module.tokens_secret.secret_arn
}

output "k0s_controller_install_association_id" {
  value = module.k0s_controller_install.association_id
}

output "kubeconfig_secret_arn" {
  value = module.kubeconfig_secret.secret_arn
}

output "kubeconfig_secret_name" {
  value = module.kubeconfig_secret.secret_name
}

output "kubeconfig" {
  description = "Current admin kubeconfig content (the placeholder until scripts/get_kubeconfig.sh has pushed the real one)"
  value       = module.kubeconfig_secret.kubeconfig
  sensitive   = true
}

data "sops_file" "ssh_keys" {
  source_file = "./secrets/ssh-keys.secrets.yaml"
}
locals {
  parsed   = yamldecode(data.sops_file.ssh_keys.raw)
  ssh_keys = local.parsed.ssh_keys

  # ssh-keys.secrets.yaml also carries each entry's private_key, so the
  # whole decrypted blob (and anything derived from it, including
  # ssh_keys above) is sensitive — Terraform won't allow that in a
  # for_each even if you unwrap individual fields inline. Build a copy
  # containing only the two non-secret fields actually needed, then
  # strip sensitivity from that whole (already private_key-free) copy.
  ssh_keys_public = nonsensitive([
    for k in local.ssh_keys : { name = k.name, public_key = k.public_key }
  ])
}

resource "aws_key_pair" "access_key_pairs" {
  for_each   = { for k in local.ssh_keys_public : k.name => k.public_key }
  key_name   = each.key
  public_key = trimspace(each.value)
}