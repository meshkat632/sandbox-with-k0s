# K3k host cluster on EC2 (single-node K3s, HCP Terraform)

One Ubuntu 24.04 EC2 instance in the **default VPC** with an auto-assigned public IP,
running K3s as **control plane + worker**. On every boot the instance writes its admin
kubeconfig (pointing at its current public IP) to **AWS Secrets Manager**.

```
HCP Terraform ──apply──▶ SG + IAM role + Secret + EC2
                                         │ user-data
                                         ▼
                          K3s server (cp + worker)
                                         │ systemd: k3s-kubeconfig-publish
                                         ▼
                   Secrets Manager: k3k-host/kubeconfig
```

## Layout

| Path | Purpose |
|---|---|
| `versions.tf` | `cloud {}` block (HCP Terraform) + AWS provider |
| `main.tf` | default VPC lookup, SG, secret, instance role, EC2 |
| `templates/user-data.sh.tftpl` | installs K3s, keeps TLS SAN = current public IP, publishes kubeconfig |
| `outputs.tf` | public IP, API URL, secret ARN, fetch command |
| `bootstrap-oidc/` | one-time: OIDC trust so HCP Terraform assumes an AWS role (no static keys) |

## 1. One-time: AWS credentials for HCP Terraform (OIDC)

Run locally with admin credentials:

```sh
cd bootstrap-oidc
terraform init
terraform apply -var tfc_organization=<your-org> -var tfc_workspace=k3k-host-cluster
```

In the HCP Terraform workspace, add these **environment variables** (from the output):

| Key | Value |
|---|---|
| `TFC_AWS_PROVIDER_AUTH` | `true` |
| `TFC_AWS_RUN_ROLE_ARN` | `arn:aws:iam::<acct>:role/k3k-host-tfc-runner` |

(Alternative: set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` as sensitive env vars and skip this step.)

## 2. Configure and apply

1. Edit `versions.tf`: set `organization` (and workspace name if different).
2. Optional: set Terraform variables in the workspace (see `terraform.tfvars.example`).
3. Run:

```sh
terraform login
terraform init
terraform apply
```

or connect the workspace to a VCS repo and let HCP Terraform run on push.

## 3. Get the kubeconfig

K3s needs ~2–4 minutes after `apply` finishes. Then:

```sh
aws secretsmanager get-secret-value --region eu-central-1 \
  --secret-id k3k-host/kubeconfig --query SecretString --output text > k3k-host-kubeconfig.yaml
export KUBECONFIG=$PWD/k3k-host-kubeconfig.yaml
kubectl get nodes
```

(`terraform output get_kubeconfig_command` prints the exact command.)

## 4. Next: install K3k

```sh
helm repo add k3k https://rancher.github.io/k3k && helm repo update
helm install k3k k3k/k3k -n k3k-system --create-namespace
```

For HCP virtual clusters exposed via NodePort, open the NodePort range to your
worker networks: `nodeport_allowed_cidrs = ["<worker-cidr>"]`.

## Behaviour notes

- **No Elastic IP**: the public IP changes after a stop/start. A systemd drop-in rewrites
  `/etc/rancher/k3s/config.yaml` (`tls-san`, `node-external-ip`) before K3s starts, and
  the publish service pushes a fresh kubeconfig to the secret. Re-fetch the secret after
  a restart. Anything pinned to the old IP (e.g. HCP `tlsSANs`, worker `K3S_URL`) must be
  updated — use an EIP or DNS name if that matters.
- **API open to the world** (`api_allowed_cidrs = ["0.0.0.0/0"]`) as requested. It is still
  protected by client certificates, but restrict it when you can.
- **Shell access** via SSM Session Manager (`terraform output ssm_session_command`);
  SSH is closed unless you set `ssh_allowed_cidrs` + `key_name`.
- **Instance role** can only write that one secret. IMDSv2 with hop limit 1 keeps pods
  from using the instance credentials.
- The secret contains **cluster-admin** credentials. `recovery_window_in_days = 0`, so
  `terraform destroy` deletes it immediately.
- Bootstrap log on the node: `/var/log/k3s-bootstrap.log`;
  publish log: `journalctl -u k3s-kubeconfig-publish`.
