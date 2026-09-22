# k0stool infrastructure

Terraform stack for a sandbox [k0s](https://k0sproject.io/) Kubernetes cluster on AWS.
Minimal by design: one VPC with public subnets only (no NAT), EC2 nodes launched
from a launch template, IAM-only AWS access (no static credentials on nodes),
and secrets delivered via sops-encrypted files committed to git.

- **Region:** `eu-central-1` (configurable via `var.region`)
- **Node OS:** latest Ubuntu 24.04 (resolved per region at plan time)

## Architecture

```
                        ┌────────────────────────────────────────────┐
                        │                    VPC                     │
                        │               10.0.0.0/16                  │
                        │                                            │
   internet ◄────► ┌────┴─────┐   ┌────────────┐   ┌────────────┐   │
                   │    IGW   │──►│ subnet a   │   │ subnet b   │   │
                   └──────────┘   │ 10.0.1.0/24│   │ 10.0.2.0/24│   │
                                  └─────┬──────┘   └─────┬──────┘   │
                                        │                │          │
                                  ┌─────┴────────────────┴──────┐   │
                                  │  route table (0.0.0.0/0→IGW)│   │
                                  └─────────────────────────────┘   │
                                                                  │
   k0s nodes (EC2, from launch template) ◄── SG: tcp/22 from ssh_cidr
   IAM instance profile: SSM core + EBS CSI + ECR pull             │
   secrets: sops-encrypted file in git ──► Secrets Manager        │
                        └────────────────────────────────────────────┘
```

## Modules

| Module | Purpose | Key inputs | Key outputs |
|---|---|---|---|
| `tf-modules/network` | VPC, internet gateway, one public subnet per AZ (round-robin CIDR→AZ), shared public route table, SSH security group | `name`, `vpc_cidr`, `public_subnet_cidrs`, `ssh_cidr` | `vpc_id`, `public_subnet_ids`, `security_group_id`, route table / IGW ids |
| `tf-modules/launch-template` | `aws_launch_template` with latest Ubuntu 24.04 AMI (or pinned `ami_id`), optional user_data, instance/volume tag specs | `name`, `instance_type`, `key_name`, `security_group_ids`, `iam_instance_profile_name`, `user_data` | `id`, `latest_version`, `ami_id` |
| `tf-modules/instances` | Launches N instances from the template, spread across subnets; `Name = <name>-<n>` | `launch_template_id`, `subnet_ids`, `instance_count` | `instance_ids`, `public_ips`, `public_dns`, `private_ips` |
| `tf-modules/ssm-instance-profile` | IAM role + instance profile for nodes: SSM core built in, extra managed policies attachable live | `name`, `extra_policy_arns` | `instance_profile_name`, `role_arn` |
| `tf-modules/secrets-from-sops` | Decrypts a sops-encrypted file and stores it in AWS Secrets Manager | `source_file`, `secret_name`, `recovery_window_in_days` | `secret_arn`, `secret_id` |

Composition lives in [main.tf](main.tf); root variables in [variables.tf](variables.tf);
root outputs (instance IPs, subnet ids, etc.) in [outputs.tf](outputs.tf).

## Prerequisites

- AWS CLI v2 with SSO access — the profile is defined in `.env`
- Terraform `>= 1.6.0`
- [sops](https://github.com/getsops/sops) + [age](https://age-encryption.org/) —
  needed because the `tokens_secret` module decrypts `secrets/tokens.secrets.yaml`
  on every plan/apply. Put the team's age private key at
  `~/.config/sops/age/keys.txt` (or export `SOPS_AGE_KEY`).

## Deploy

```bash
set -a; . ./.env; set +a          # AWS_PROFILE
terraform init
terraform plan
terraform apply
```

Useful knobs (vars or `-var` flags):

| Variable | Default | Notes |
|---|---|---|
| `environment` | `dev` | name prefix: `k0stool-<env>-…` |
| `instance_type` | `t3a.large` | minimum for multi-node k0s |
| `instance_count` | `3` | 1 controller + 2 workers, spread across AZs |
| `ssh_cidr` | `0.0.0.0/0` | tighten to your IP once SSM is verified |
| `public_key_path` | `~/.k0stool/k0stool-key.pub` | source of the `aws_key_pair` |

Changing `instance_type` or the launch template replaces running nodes
(new IPs, wiped disks).

## Connect to the nodes

### SSH

The AWS key pair is created from `var.public_key_path` (default
`~/.k0stool/k0stool-key.pub`); the matching private key is what you connect with.

```bash
# one-time: make sure the key pair exists locally
mkdir -p ~/.k0stool
ssh-keygen -t ed25519 -f ~/.k0stool/k0stool-key -N "" -C k0stool   # skip if it already exists
terraform apply    # registers the public key as an EC2 key pair (named var.key_name)

# connect (user is ubuntu)
ssh -i ~/.k0stool/k0stool-key \
    -o StrictHostKeyChecking=accept-new \
    ubuntu@$(terraform output -raw k0s_node_public_ips | jq -r '.[0]')
```

Multiple nodes — list them or loop:

```bash
terraform output -json k0s_node_public_ips | jq -r '.[]'      # all IPs

for ip in $(terraform output -json k0s_node_public_ips | jq -r '.[]'); do
  ssh -i ~/.k0stool/k0stool-key -o StrictHostKeyChecking=accept-new \
      ubuntu@$ip 'hostname; sudo k0s status'
done
```

Newly launched instances need ~30–60s of boot time before sshd accepts connections.

### SSM (no SSH key, no open port)

Nodes carry the `k0stool-dev-ssm-profile` instance profile:

```bash
aws ssm start-session --target $(terraform output -raw k0s_node_ids | jq -r '.[0]')
```

Run a script on one or many nodes (console: Systems Manager → Session Manager /
Fleet Manager; CLI needs the Session Manager plugin):

```bash
aws ssm send-command \
  --instance-ids $(terraform output -raw k0s_node_ids | jq -r '.[0]') \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["curl -sSfL https://get.k0s.sh | sudo sh"]}'
```

## Secrets (gitops)

Encrypted secrets are committed to `secrets/` (sops + age). To rotate or add a
secret: edit the file with `sops secrets/<file>.yaml` (decrypts on open,
re-encrypts on save) and apply. See the `makefile` for helper targets (`make tools`,
`make age-key`, `make decrypt FILE=…`).

> Note: the makefile's `keypair`/`secret`/`rotate` targets expect a
> `secrets/ssh-keypair.enc.yaml` that is not in this repo — SSH keys here come
> from the local file at `public_key_path` instead. Adjust or trim those targets
> if they stay unused.

## Costs (eu-central-1, on-demand, per node)

| Type | ~$/month |
|---|---|
| t3.micro | ~$8.5 |
| t3a.large (2 vCPU / 8 GB) | ~$63 |
| + 8 GB gp3 root volume | ~$0.8 |
