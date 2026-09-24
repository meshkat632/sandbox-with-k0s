# codespace

A single-node [k0s](https://k0sproject.io) Kubernetes dev box on AWS, managed
with Terraform. One EC2 instance (Ubuntu 24.04) runs the k0s controller and
worker, has a fixed Elastic IP, and is provisioned by cloud-init.

## What it creates

- EC2 instance (default `r7i.2xlarge`, 100 GiB encrypted gp3) in `subnet_id`, or
  the default VPC if unset
- Elastic IP, so the address survives stop/start
- Key pair (public key from `secrets.yaml`), security group (SSH `22` and
  Kubernetes API `6443`, both limited to `allowed_cidrs`; HTTP `80` and HTTPS
  `443` for ingress-nginx, open to `web_allowed_cidrs`, the internet by default)
- IAM role + instance profile: SSM, EBS CSI and ECR pull policies, and write
  access to the kubeconfig secret
- Secrets Manager secret `codespace-kubeconfig` holding the admin kubeconfig

On first boot cloud-init runs, in order:

1. `scripts/bootstrap.sh.tftpl`: base packages, a Python venv with
   `python_packages`, `~/workspace`
2. `scripts/k0s.sh.tftpl`: downloads the pinned `k0s_version` from GitHub,
   verifies it against the release's `sha256sums.txt`, installs it as a
   single-node controller, adds the
   Elastic IP to the API certificate, and sets up `kubectl` for `ubuntu`

As its last step, `k0s.sh` writes the admin kubeconfig to the Secrets Manager
secret, using the instance role. Terraform itself never connects to the
instance, so it can run anywhere, including Terraform Cloud runners, without
their IPs being allowed in the security group. The instance takes a few
minutes after `apply` to finish; `make kubeconfig` reports "holds no
kubeconfig yet" until it has.

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

**4. Create `secrets.yaml`** from the template, fill in the DB password and your
`public_key` (`~/.ssh/codespace_ed25519.pub`), then encrypt it (`make` needs the `.env` from step 3):

```sh
cp secrets.yaml.example secrets.yaml
$EDITOR secrets.yaml
make encrypt                 # encrypts the password values in place
```

Use `make decrypt` / `make encrypt` to edit the file later. The private key
stays in `~/.ssh`; Terraform only needs the public key.

**5. Provision and connect:**

```sh
make plan          # init + validate + plan, saved to ./tfplan
make apply         # creates the instance; k0s installs and publishes the kubeconfig in ~5 min
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
| `lint`       | `fmt -check` + `validate`, no credentials needed (CI-safe) |
| `validate`   | Check syntax and configuration                            |
| `plan`       | Create an execution plan (`VARS="-var name_suffix=demo01"` for extra args) |
| `apply`      | Apply the saved plan                                      |
| `destroy`    | Destroy all resources                                     |
| `output`     | Show outputs, including sensitive ones                    |
| `decrypt` / `encrypt` | Decrypt / encrypt `secrets.yaml` with SOPS       |
| `ssh`        | SSH into the instance                                     |
| `kubeconfig` | Fetch the kubeconfig from Secrets Manager and select it   |
| `deploy`     | Apply a manifest through SSM (`MANIFEST=`, `NAMESPACE=`, `DRY_RUN=1`) |
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
placeholder: the instance is still installing k0s (wait a few minutes) or the
last step of `/var/log/codespace-k0s.log` failed (`make ssh`, or an SSM session).

## Uploading files to the instance

Anything you put in `files/` (`upload_dir`) is copied to
`/opt/codespace/files` (`upload_destination`) on the instance, mode `755`,
owned by root, keeping subfolders. Hidden files and folders are skipped.

```sh
cp my-script.sh files/
make plan && make apply       # or push, for Terraform Cloud
make ssh                      # then: /opt/codespace/files/my-script.sh
```

How it works (`upload.tf`): the files are embedded, base64-encoded, in an
SSM command document, and an SSM association runs it on the instance. Like
the rest of the stack this is AWS API calls only, so it works from Terraform
Cloud. Changing the files creates a new document version and re-runs the
association; unlike the boot scripts, it does **not** replace the instance.
A replaced instance gets the files too.

- The destination is a mirror: files you delete from `files/` are removed
  from the instance. The upload is staged and swapped in, so the directory is
  never half-written.
- An SSM document is limited to 64 KB, so keep it to scripts and small config
  files (about 45 KB in total). The plan fails with a message if it's larger.
- File names may only contain letters, digits and `._-/`.
- `apply` waits (up to 10 minutes) for the upload to succeed, so the instance
  must be running. After a `make stop`, run `make start` before applying.
- The credentials running Terraform need SSM document and association
  permissions (`ssm:CreateDocument`, `ssm:UpdateDocument`,
  `ssm:CreateAssociation`, `ssm:UpdateAssociation`,
  `ssm:DescribeAssociation`, and their delete/read counterparts).

## Deploying manifests through SSM

`make deploy` applies Kubernetes manifests without reaching the API server or
SSH. `scripts/ssm_kubectl_apply.py` sends the manifest to the instance with
SSM Run Command (gzipped and base64-encoded inside the command) and runs
`k0s kubectl apply` there as root. It only needs AWS credentials with
`ssm:SendCommand`, `ssm:GetCommandInvocation` and `ec2:DescribeInstances`.

```sh
make deploy MANIFEST=app.yaml                  # a file
make deploy MANIFEST=manifests/ NAMESPACE=apps # every *.yaml / *.yml in a directory, sorted
make deploy MANIFEST=app.yaml DRY_RUN=1        # server-side dry run, changes nothing
```

The first run creates a virtualenv with boto3 in `<repo>/.venv`. The script
can also be run directly and reads stdin with `-`:

```sh
kubectl create deploy web --image=nginx -o yaml --dry-run=client \
  | ../../.venv/bin/python ../../scripts/ssm_kubectl_apply.py -n apps -
```

It finds the running instance tagged `Project=codespace` (or pass
`--instance-id`) and exits with kubectl's exit code. Limits: the compressed
manifest must be under 48 KiB (several hundred KiB of plain YAML), and SSM
keeps only the first 24,000 characters of kubectl's output.

## Variables

| Variable                 | Default                  | Description                                        |
| ------------------------ | ------------------------ | -------------------------------------------------- |
| `allowed_cidrs`          | (required)               | CIDRs allowed to reach SSH and the API server      |
| `web_allowed_cidrs`      | `["0.0.0.0/0"]`          | CIDRs allowed to reach HTTP/HTTPS; `[]` closes them |
| `region`                 | `eu-central-1`           | AWS region                                         |
| `tags`                   | Project, Environment, ManagedBy | Default tags on every resource              |
| `subnet_id`              | `null` (default VPC)     | Subnet for the instance                            |
| `name_suffix`            | random 6-char hex        | Fixed suffix for resource names (`codespace-<suffix>`) |
| `instance_type`          | `r7i.2xlarge`            | EC2 instance type (x86_64)                         |
| `root_volume_size`       | `100`                    | Root volume, GiB                                   |
| `python_packages`        | numpy, pandas, requests, ruff, pytest | Installed into `~/.venvs/dev`         |
| `k0s_version`            | `v1.36.4+k0s.1`          | k0s release tag; pinned for reproducible rebuilds  |
| `extra_policy_arns`      | EBS CSI, ECR pull        | Managed policies added to the instance role        |
| `kubeconfig_secret_name` | `codespace-kubeconfig`   | Secrets Manager secret for the kubeconfig          |
| `kubeconfig_recovery_window_in_days` | `0`          | Days the secret is recoverable after destroy (0 or 7-30) |
| `upload_dir`             | `files`                  | Folder mirrored to the instance through SSM        |
| `upload_destination`     | `/opt/codespace/files`   | Where it is mirrored on the instance               |

Inputs are validated at plan time: `allowed_cidrs` must not contain
`0.0.0.0/0`, `instance_type` must support x86_64, and `python_packages`
entries must be plain pip requirements (they end up in a shell script).

## Outputs

`name`, `instance_id`, `region`, `public_ip`, `ami_name`,
`security_group_id`, `kubeconfig_secret_name`, `ssh_command`, `ssm_command`,
`uploaded_files`.

## Notes

- Access without SSH: `aws ssm start-session --target <instance_id>`
  (see the `ssm_command` output).
- By default the kubeconfig secret has no recovery window, so `make destroy`
  deletes it immediately (see `kubeconfig_recovery_window_in_days`).
- To upgrade k0s, bump `k0s_version`. This replaces the instance, and with
  it the cluster; it is not an in-place upgrade.
- `.terraform.lock.hcl` is committed so local and Terraform Cloud runs use the
  same provider builds. After changing provider versions run `make init` and
  commit the updated lock file.
- The Elastic IP is in the API certificate's SANs, so kubectl verifies TLS
  against it. If you replace the instance the certificate is regenerated;
  run `make kubeconfig` again.
- Terraform state holds secrets (the decrypted `secrets.yaml`); keep
  it private and never commit it.

## Running in Terraform Cloud

Runs on Terraform Cloud runners need no network access to the instance, since
Terraform makes only AWS API calls. Set these on the workspace:

- Working directory `stacks/codespace`
- AWS credentials: `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (sensitive
  environment variables) or dynamic credentials
- `SOPS_AGE_KEY`: contents of your age private key (sensitive environment
  variable), so the sops provider can decrypt `secrets.yaml`
- Terraform variable `allowed_cidrs`: your own IP(s), for SSH and the API

`.env` and the `plan`/`apply` Makefile targets are for local runs
(saved plans with `-out` are not supported by remote runs). `make kubeconfig`
works either way, because it only talks to Secrets Manager.
