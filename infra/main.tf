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

resource "aws_key_pair" "this" {
  key_name   = var.key_name
  public_key = trimspace(file(pathexpand(var.public_key_path)))
}

module "tokens_secret" {
  source      = "./tf-modules/secrets-from-sops"
  source_file = "${path.root}/secrets/tokens.secrets.yaml"
  secret_name = "sandbox/tokens-test-v5"

  expose_debug_output = true # flip to false once verified

  tags = {
    Environment = "sandbox"
  }
}

module "network" {
  source = "./tf-modules/network"

  name                = "k0stool-${var.environment}"
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
  ssh_cidr            = var.ssh_cidr
  kube_api_cidrs      = var.kube_api_cidrs
}

module "ssm_profile" {
  source = "./tf-modules/ssm-instance-profile"

  name = "k0stool-${var.environment}"

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

  name                      = "k0stool-${var.environment}"
  instance_type             = var.instance_type
  key_name                  = aws_key_pair.this.key_name
  security_group_ids        = [module.network.security_group_id]
  iam_instance_profile_name = module.ssm_profile.instance_profile_name
  user_data                 = module.node_bootstrap.user_data
}

module "k0s_nodes" {
  source = "./tf-modules/instances"

  name               = "k0stool-${var.environment}-node"
  launch_template_id = module.launch_template.id
  subnet_ids         = module.network.public_subnet_ids
  instance_count     = var.instance_count
}

output "tokens_secret_arn" {
  value = module.tokens_secret.secret_arn
}
