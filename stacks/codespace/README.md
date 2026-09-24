# codespace

A single-node [k0s](https://k0sproject.io) Kubernetes dev box on AWS, managed
with Terraform. One EC2 instance (Ubuntu 24.04) runs the k0s controller and
worker, has a fixed Elastic IP, and is provisioned by cloud-init.

## What it creates

- EC2 instance (default `r7i.2xlarge`, 100 GiB encrypted gp3) in the default VPC
- Elastic IP, so the address survives stop/start
- Key pair (public key from `secrets.yaml`), security group (SSH `22` and
  Kubernetes API `6443`, both limited to `allowed_cidrs`)
- IAM role + instance profile: SSM, plus EBS CSI and ECR pull policies
- Secrets Manager secret `codespace-kubeconfig` holding the admin kubeconfig

On first boot cloud-init runs, in order:

1. `scripts/bootstrap.sh.tftpl`: base packages, a Python venv with
   `python_packages`, `~/workspace`
2. `scripts/k0s.sh.tftpl`: installs k0s as a single-node controller, adds the
   Elastic IP to the API certificate, and sets up `kubectl` for `ubuntu`

Terraform then waits until the instance is healthy (EC2 status checks, SSM
online, cloud-init done, `kubectl get nodes`) and pushes the kubeconfig
to the secret.

> Any change to the scripts or their variables **replaces the instance**
> (`user_data_replace_on_change`), because cloud-init only runs on first boot.

## Prerequisites

- `terraform` >= 1.6, `aws` CLI, `kubectl`, `sops`
- AWS credentials with rights for EC2, IAM, Secrets Manager and SSM
- The SOPS key configured in the repo's `.sops.yaml`

## Setup

Create `.env` in this directory (it is sourced by the Makefile):

```sh
export AWS_PROFILE=<your-profile>
export TF_VAR_allowed_cidrs='["203.0.113.10/32"]'   # your public IP
```

`secrets.yaml` is SOPS-encrypted and holds the DB credentials and SSH key
pair used for the instance. Use `make decrypt` / `make encrypt` to edit it.
The private key is used by Terraform for the readiness check and the
kubeconfig push. To SSH yourself (`make ssh`) put it at
`~/.ssh/codespace_ed25519` (override with `SSH_KEY=`).

## Usage

```sh
make plan          # init + validate + plan, saved to ./tfplan
make apply         # apply the saved plan
make kubeconfig    # merge the cluster into ~/.kube/config and switch to it
```

Run `make help` for all targets.

| Target       | What it does                                              |
| ------------ | --------------------------------------------------------- |
| `init`       | Download providers/modules                                |
| `fmt`        | Format all `.tf` files                                    |
| `validate`   | Check syntax and configuration                            |
| `plan`       | Create an execution plan (`VARS="-var name_suffix=demo01"` for extra args) |
| `apply`      | Apply the saved plan                                      |
| `destroy`    | Destroy all resources                                     |
| `output`     | Show outputs, including sensitive ones                    |
| `decrypt` / `encrypt` | Decrypt / encrypt `secrets.yaml` with SOPS       |
| `ssh`        | SSH into the instance                                     |
| `kubeconfig` | Fetch the kubeconfig from Secrets Manager and select it   |
| `status`     | Show instance state and IP                                |
| `stop`       | Stop the instance (disk, Elastic IP and state are kept)   |
| `start`      | Start the instance and wait for SSH and Kubernetes        |
| `clean`      | Remove the local plan and `.terraform` cache              |

## Getting kubectl access

`make kubeconfig` does not use Terraform or SSH. It reads the secret with the
AWS CLI, writes a `codespace` cluster/user/context into `~/.kube/config`,
selects it and runs `kubectl get nodes`. It needs only
`secretsmanager:GetSecretValue` on the secret.

```sh
make kubeconfig
make kubeconfig KUBE_CONTEXT=mybox REGION=us-east-1 KUBECONFIG_SECRET=my-secret
```

`KUBECONFIG_SECRET` (default `codespace-kubeconfig`) and `REGION` (default
`eu-central-1`) must match `var.kubeconfig_secret_name` and `var.region`. If
you change one in Terraform, change it in the Makefile or pass it on the
command line.

If it says the secret holds no kubeconfig yet, the secret still contains the
placeholder: `make apply` did not finish, or the push step failed. Check
the `kubeconfig_push` output from apply.

## Variables

| Variable                 | Default                  | Description                                        |
| ------------------------ | ------------------------ | -------------------------------------------------- |
| `allowed_cidrs`          | (required)               | CIDRs allowed to reach SSH and the API server      |
| `region`                 | `eu-central-1`           | AWS region                                         |
| `name_suffix`            | random 6-char hex        | Fixed suffix for resource names (`codespace-<suffix>`) |
| `instance_type`          | `r7i.2xlarge`            | EC2 instance type (x86_64)                         |
| `root_volume_size`       | `100`                    | Root volume, GiB                                   |
| `python_packages`        | numpy, pandas, requests, ruff, pytest | Installed into `~/.venvs/dev`         |
| `k0s_version`            | `""` (latest stable)     | e.g. `v1.33.4+k0s.0`                               |
| `extra_policy_arns`      | EBS CSI, ECR pull        | Managed policies added to the instance role        |
| `kubeconfig_secret_name` | `codespace-kubeconfig`   | Secrets Manager secret for the kubeconfig          |

## Outputs

`instance_id`, `region`, `public_ip`, `ssh_command`, `ssm_command`,
`kubeconfig_secret_name`, `debug`.

## Notes

- Access without SSH: `aws ssm start-session --target <instance_id>`
  (see the `ssm_command` output).
- The kubeconfig secret has no recovery window, so `make destroy` deletes it
  immediately.
- The Elastic IP is in the API certificate's SANs, so kubectl verifies TLS
  against it. If you replace the instance the certificate is regenerated;
  run `make kubeconfig` again.
- Terraform state is local (`terraform.tfstate`); it holds secrets, so don't
  commit it.
