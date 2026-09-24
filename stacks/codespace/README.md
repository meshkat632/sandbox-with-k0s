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

- `terraform` >= 1.6, `aws` CLI, `kubectl`, [`sops`](https://github.com/getsops/sops),
  [`age`](https://github.com/FiloSottile/age), `ssh-keygen`
- An AWS account and credentials (a named profile) with rights for EC2, IAM,
  Secrets Manager and SSM

## Quick start

Run everything from `stacks/codespace/`.

**1. Create your age key** (used by sops to encrypt `secrets.yaml`). Skip if you
already have one at `~/.config/sops/age/keys.txt`.

```sh
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt      # prints your public key (age1...)
```

Put that public key in the repo's `.sops.yaml` under `age:`, replacing the
existing recipients (they belong to the repo author, so you cannot decrypt
files encrypted for them).

**2. Create the instance SSH key.** `make ssh` expects it at
`~/.ssh/codespace_ed25519` (override with `SSH_KEY=`):

```sh
ssh-keygen -t ed25519 -N "" -C you@example.com -f ~/.ssh/codespace_ed25519
```

**3. Create `.env`** from the template (the Makefile sources it):

```sh
cp .env.example .env
$EDITOR .env                 # set AWS_PROFILE and TF_VAR_allowed_cidrs (your IP)
```

`.env.example` explains each variable. To fill in your public IP:

```sh
echo "export TF_VAR_allowed_cidrs='[\"$(curl -s https://checkip.amazonaws.com)/32\"]'"
```

**4. Create `secrets.yaml`** from the template, fill in the DB password, your
`public_key` (`~/.ssh/codespace_ed25519.pub`) and `private_key`
(`~/.ssh/codespace_ed25519`), then encrypt it (`make` needs the `.env` from step 3):

```sh
cp secrets.yaml.example secrets.yaml
$EDITOR secrets.yaml
make encrypt                 # encrypts password and private_key values in place
```

Terraform uses the private key for the readiness check and the kubeconfig
push, so it stays in Terraform's state: keep `terraform.tfstate` private (it is
gitignored). Use `make decrypt` / `make encrypt` to edit the file later.

**5. Provision and connect:**

```sh
make plan          # init + validate + plan, saved to ./tfplan
make apply         # ~5 min: creates the instance, installs k0s, pushes the kubeconfig
make kubeconfig    # merge the cluster into ~/.kube/config and switch to it
kubectl get nodes
```

**6. Tear down** when you are done: `make destroy`.

## Make targets

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
