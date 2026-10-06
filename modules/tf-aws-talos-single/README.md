# tf-aws-talos-single

One EC2 instance in the default VPC = one complete Talos Kubernetes cluster
(control plane + worker in a single node). Ephemeral public IP, no Elastic IP.

## What it does, in order

1. Resolves the default VPC + its public subnet
2. Finds the official Talos AMI for the provider's region + arch (override with `ami_id`)
3. Creates a locked-down SG (50000 + 6443 from your IP only)
4. Launches the instance (gp3 root disk, `disk_size` GiB, auto-assigned public IP)
5. Generates Talos cluster secrets
6. Renders the control-plane config (patched: allowSchedulingOnControlPlanes,
   installer image pinned to `talos_semver`, install disk `/dev/nvme0n1`)
7. Applies config to the node over the Talos API (:50000) - connects to the
   public IP (endpoint), addresses the node by its private IP
8. Bootstraps etcd -> cluster exists
9. Retrieves the admin kubeconfig

## Usage

The module does not configure the AWS provider and has no `region` input:
the caller configures the provider, and the module reads the region from it.
Requires AWS provider >= 6.0.

    provider "aws" {
      region = "eu-central-1"
    }

    module "talos_single" {
      source       = "../../"
      cluster_name = "tryout-single"
    }

Run the example. It keeps its state in HCP Terraform (org `sandbox-v1`,
workspace `talos-single-test`, execution mode **local**: Terraform still runs
on your machine with your AWS credentials, so the IP-restricted security group
and the Makefile targets work). Run `terraform login` once, or change the
`cloud` block in `examples/basic/versions.tf` for your own org. A workspace
that `terraform init` creates for you gets the org default, usually remote
execution - switch it to local, since HCP runners can't reach the node.

    cd examples/basic
    terraform init
    terraform apply
    make nodes              # installs the kubeconfig, runs kubectl get nodes

    # tear down
    terraform destroy

The example's Makefile handles the kubeconfig:

- `make kubeconfig` - copy the admin kubeconfig to
  `~/.kube/configs/<cluster_name>.yaml` (mode 600, one file per cluster;
  override the folder with `KUBECONFIG_DIR=...`). The context is
  `admin@<cluster_name>`. Remove the file after a destroy.
- `make nodes` - `kubectl get nodes -o wide` against that file

To measure how long a usable cluster takes, create it with `make timed-up`
instead of `terraform apply` (it auto-approves, so no prompt time is counted).
It waits until the node is Ready, CoreDNS is rolled out and all kube-system
pods are Ready, then appends a row to `examples/basic/timings.csv`:
terraform apply seconds, apply -> ready seconds, total, Kubernetes and Talos
versions. `make timings` prints the recorded runs.

## Known caveats (read before using beyond a lab)

- The Talos resources and the generated talosconfig use endpoint = public IP,
  node = private IP. Don't point `node` at the public IP: the Talos API
  forwards to it, and the SG doesn't let the node reach its own public IP
  -> bootstrap hangs.
- The install disk is hardcoded to `/dev/nvme0n1` (Nitro types such as
  `t3.*` / `t4g.*`). Older Xen instance types need a different disk.
- **No Elastic IP on purpose**: if you stop/start the instance, AWS gives it a
  NEW public IP. The cluster endpoint, API server cert SANs and your
  kubeconfig all reference the OLD IP -> the cluster breaks. Fine for
  throwaway/testing; never stop the instance if you want it to survive.
- Single-node etcd has no redundancy: instance loss = cluster loss.
  The module's on_destroy resets the node to maintenance mode (non-graceful:
  the only etcd member can't leave its own cluster).
- `allowed_cidr` defaults to the IP you run terraform from.
- Secrets land in TF state as usual - this is a lab pattern.
