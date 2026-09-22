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
| `tf-modules/node-bootstrap` | Renders the launch template's `user_data`: `apt-get update` then `apt-get install` a fixed package list, run by cloud-init on first boot of every node | `packages` (default: curl, unzip, jq, git, open-iscsi) | `user_data` |
| `tf-modules/instances` | Launches N instances from the template, spread across subnets; `Name = <name>-<n>` | `launch_template_id`, `subnet_ids`, `instance_count` | `instance_ids`, `public_ips`, `public_dns`, `private_ips` |
| `tf-modules/ssm-instance-profile` | IAM role + instance profile for nodes: SSM core built in, extra managed policies attachable live | `name`, `extra_policy_arns` | `instance_profile_name`, `role_arn` |
| `tf-modules/secrets-from-sops` | Decrypts a sops-encrypted file and stores it in AWS Secrets Manager | `source_file`, `secret_name`, `recovery_window_in_days` | `secret_arn`, `secret_id` |
| `tf-modules/api-server-access` | Adds one `aws_vpc_security_group_ingress_rule` per CIDR for the k8s API port against an existing security group, so it can run alongside a security group's own inline-managed rules without conflict | `security_group_id`, `cidr_blocks`, `port` (default `6443`) | `rule_ids` |
| `tf-modules/kubeconfig-secret` | Creates an (initially placeholder) Secrets Manager secret to hold the admin kubeconfig; `scripts/get_kubeconfig.sh` populates the real content after the controller is bootstrapped | `secret_name`, `recovery_window_in_days` | `secret_arn`, `secret_name` |

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
| `instance_count` | `1` | start at 1, raise it later and join the new nodes — see "Scaling" below |
| `ssh_cidr` | `0.0.0.0/0` | tighten to your IP once SSM is verified |
| `public_key_path` | `~/.k0stool/k0stool-key.pub` | source of the `aws_key_pair` |
| `kube_api_cidrs` | `[]` | CIDRs allowed to reach the k8s API (6443) from outside the VPC; empty = closed, use SSM tunnel instead |
| `public_key` | `null` | raw public key content; set this (not `public_key_path`) on Terraform Cloud, which can't read a local file |
| `name_suffix` | `null` (auto-random) | appended to every account/region-unique name so a second state (e.g. a TFC workspace) can run against the same AWS account without colliding. Leave unset for a new state; pin it (e.g. `""`) for a state with real resources already — changing it later renames, and therefore replaces, all of them |

Running a second, independent stack against the same AWS account (e.g. a
Terraform Cloud workspace alongside your local state) just needs its own
state and to leave `name_suffix` unset — no other coordination required.

Changing `instance_type` or the launch template replaces running nodes
(new IPs, wiped disks).

Bumping the launch template's `user_data` (e.g. editing `node-bootstrap`'s
`packages`) does **not** replace already-running nodes — it only takes effect
on the next boot. To force existing nodes to pick it up, taint and reapply
them, or run the same install command over SSM (see below).

## Scaling

Start with a single node and grow the cluster as needed, without touching
already-running nodes:

1. **Bootstrap node 1 as a controller that also runs pods**, so a single
   node is a fully working cluster on its own. SSH or SSM in (see
   "Connect to the nodes" below), copy `scripts/install_k0s.py` over, then:
   ```bash
   sudo python3 install_k0s.py --role controller --enable-worker
   ```
   Do **not** use `k0s install controller --single` — that mode can never
   join other nodes later, even with `--enable-worker`.

2. **When you need more capacity, raise `instance_count` and apply.**
   `aws_instance` is count-indexed, so this only ever appends new
   instances at the next index — existing nodes (and their `k0s`
   installs) are untouched:
   ```bash
   terraform apply -var 'instance_count=3'   # or edit terraform.tfvars
   ```
   (Lowering `instance_count` destroys the *highest*-indexed instances —
   don't lower it below the number of nodes you've actually bootstrapped.)

3. **Join the new instances as workers:**
   ```bash
   terraform output -json k0s_node_ids | jq -r '.[]'   # find the new ids
   scripts/join_workers.sh <new-instance-id> [<new-instance-id> ...]
   ```
   This generates a fresh join token on the controller and installs/starts
   `k0s` as a worker on each instance you pass, over SSM — the same flow
   used to bootstrap the original workers, just automated. Verify with
   `kubectl get nodes`.

Whether the controller should also run pods (`--enable-worker`) once you
have dedicated workers is a judgment call — mixing control-plane and
workload traffic is fine for a sandbox cluster like this one, less so
once you care about isolating the control plane.

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

### Kubeconfig

Once a controller has been bootstrapped (`scripts/install_k0s.py --role controller`),
pull its admin kubeconfig over SSM with:

```bash
scripts/get_kubeconfig.sh
```

By default it looks up a running instance tagged `k0s-role=controller`
(override with `-t TAG_KEY=VALUE`, or skip lookup entirely with
`-i <instance-id>`) — note nothing in this Terraform config sets that tag
yet, so tag the controller instance yourself, or pass `-i` explicitly. It
writes to `~/.kube/config-k0stool` (`-o <path>` to change), rewriting the
API server address from k0s's internal address to the controller's public
IP, and prints the `export KUBECONFIG=...` line to run afterward.

By default it also pushes the fetched kubeconfig to the
`kubeconfig_secret_name` Secrets Manager secret (pass `-S` to skip), so
anyone with `secretsmanager:GetSecretValue` on it can fetch the same
kubeconfig without SSM access of their own:
```bash
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw kubeconfig_secret_name)" \
  --query SecretString --output text > ~/.kube/config-k0stool
```

Reaching the API server from outside the VPC needs two things:

1. **Network access.** Port 6443 is only open to the VPC CIDR and to
   `var.kube_api_cidrs` (empty/closed by default). Set it, e.g.:
   ```bash
   terraform apply -var 'kube_api_cidrs=["<your-ip>/32"]'
   ```
   or reach it without opening anything, through an SSM port-forward
   session instead:
   ```bash
   aws ssm start-session --target <controller-instance-id> \
     --document-name AWS-StartPortForwardingSession \
     --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}'
   ```
   (then point the kubeconfig's `server:` at `https://localhost:6443`).

2. **A trusted certificate.** k0s's API server cert only has SANs for the
   node's own private IP / localhost / cluster service IP — never the
   public IP, so `kubectl` fails certificate verification even once the
   port is open. Either tunnel via SSM above (the private IP/localhost
   *are* in the SAN list), or pass `-k` to `get_kubeconfig.sh` to write
   the file with `insecure-skip-tls-verify: true` instead of the CA data.

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
