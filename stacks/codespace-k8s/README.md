# codespace-k8s

Kubernetes resources inside the [codespace](../codespace) cluster, managed with
the Terraform `kubernetes` provider. Currently: the namespaces in
`var.namespaces` (default `apps`), labelled
`app.kubernetes.io/managed-by=terraform`.

It is a separate stack on purpose. The codespace stack only makes AWS API
calls, so it can run anywhere. This one talks to the Kubernetes API on port
6443, and a provider can't be configured from a cluster that is created in
the same apply.

## How it connects

It reads the admin kubeconfig that the codespace instance publishes to
Secrets Manager (`kubeconfig_secret_name`, default `codespace-kubeconfig`)
and configures the provider from it on every run, so a rebuilt cluster (new
CA and certificates) needs no change here. If the secret still holds the
placeholder, the plan stops with a message saying so.

## Usage

Apply the codespace stack first and wait until `make kubeconfig` in
`stacks/codespace` succeeds. Then, from `stacks/codespace-k8s/`:

```sh
make plan     # init + validate + plan, saved to ./tfplan
make apply
kubectl get ns -l app.kubernetes.io/managed-by=terraform
```

The Makefile sources `../codespace/.env` (override with `ENV_FILE=`); only
`AWS_PROFILE` matters here. Where you run it must be in the codespace stack's
`allowed_cidrs`, since that also guards port 6443.

## Variables

| Variable                 | Default                | Description                                         |
| ------------------------ | ---------------------- | --------------------------------------------------- |
| `namespaces`             | `["apps"]`             | Namespaces to create (not the built-in ones)        |
| `region`                 | `eu-central-1`         | Region of the kubeconfig secret                     |
| `kubeconfig_secret_name` | `codespace-kubeconfig` | Must match the codespace stack's secret name        |

## Outputs

`namespaces`, `cluster_endpoint`.

## Notes

- Removing a namespace from `namespaces` (or `make destroy`) deletes it and
  **everything in it**.
- If the codespace instance is replaced, the new cluster starts without these
  namespaces. The next plan notices they are gone and creates them again.
- Terraform state holds the kubeconfig's admin credentials (the data source
  result); keep it private.

## Running in Terraform Cloud

Create a separate workspace with working directory `stacks/codespace-k8s`,
AWS credentials as for the codespace workspace, and no SOPS key (this stack
decrypts nothing). Terraform Cloud's shared runners can't reach port 6443
unless their IP ranges are in the codespace stack's `allowed_cidrs`. Either
run this stack locally (a CLI-driven workspace with local execution), or use
a Terraform Cloud agent inside the VPC.
