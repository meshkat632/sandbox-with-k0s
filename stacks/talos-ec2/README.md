# talos-ec2

A single-node [Talos](https://www.talos.dev) Kubernetes cluster on one EC2
instance, sized to fit the AWS free tier. The node is the control plane and
also runs the workloads. Extra worker nodes are optional.

Everything is configured in one file, [`cluster.yaml`](cluster.yaml), a
CAPI-style `Cluster` object. `terraform apply` creates:

- a security group in the default VPC: the Talos API (50000) and the
  Kubernetes API (6443) are open to **your current public IP only**; 80/443
  are open to `httpIngress.allowedCIDRBlocks`; nodes reach each other freely;
- the EC2 instance from the official Talos AMI, with an ephemeral public IP;
- a separate gp3 data disk (`dataVolume.size`), which Talos mounts at
  `/var/mnt/local-storage` for persistent volumes;
- the Talos machine config, the bootstrap, and the Talos client config
  published to SSM Parameter Store (`/talos/<cluster name>/talosconfig`);
- `workers.replicas` extra worker instances that join the cluster;
- the add-ons listed under `addons.install`, by running `make addons`.

State is local (`terraform.tfstate`, not committed).

## Requirements

On the machine that runs Terraform:
`terraform`, `aws` (with credentials for the account), `talosctl`, `kubectl`,
`helm`, `git` and `make`.

## Usage

```bash
terraform init
terraform apply        # cluster + add-ons
make nodes             # fetch the kubeconfig, kubectl get nodes
terraform destroy
```

`make help` lists all targets.

### kubeconfig

`make kubeconfig` writes `~/.kube/configs/<cluster name>.yaml` (override the
folder with `KUBECONFIG_DIR`). It does not use Terraform: it reads the Talos
client config from SSM, asks the node for a fresh admin kubeconfig over the
Talos API, and waits until the API server is ready (`WAIT_SECONDS`, default
300).

Talos has no SSH. For node-level access use `talosctl` with the same client
config:

```bash
aws ssm get-parameter --region eu-central-1 --name /talos/talos-dev/talosconfig \
  --with-decryption --query Parameter.Value --output text > talosconfig
talosctl --talosconfig talosconfig dashboard
```

## cluster.yaml

| Field | Meaning |
| ----- | ------- |
| `metadata.name` | Cluster name; also names the AWS resources and the kubeconfig file |
| `spec.infrastructure.region` | AWS region |
| `spec.infrastructure.additionalTags` | Tags on every AWS resource |
| `spec.infrastructure.network.httpIngress.allowedCIDRBlocks` | Who may reach 80/443; `[]` closes them. Let's Encrypt needs `0.0.0.0/0` |
| `spec.controlPlane.version` | Kubernetes version |
| `spec.controlPlane.machineTemplate.spec.instanceType` | One of the free-tier types that can run Talos (listed in the file) |
| `...rootVolume.size` / `...dataVolume.size` | Disk sizes in GiB; together at most 30. `dataVolume.size: 0` = no data disk |
| `spec.controlPlane.controlPlaneConfig.talosVersion` | Exact Talos release (AMI and installer) |
| `spec.controlPlane.controlPlaneConfig.strategicPatches` | Optional extra Talos machine-config patches |
| `spec.workers.replicas` | Number of extra worker nodes; `0` = single node |
| `spec.workers.machineTemplate.spec` | `instanceType` and `rootVolume.size` of the workers |
| `spec.addons.install` | Add-ons to install (see below) |

The plan fails on a non-free-tier instance type, more than 30 GiB of disk, or
an unknown add-on name.

## Worker nodes

Set `spec.workers.replicas` in `cluster.yaml` and run `terraform apply`. Each
worker ([`modules/workers`](modules/workers)) is an instance from the Talos AMI
that gets a worker config and joins through the control plane's private IP;
`make nodes` shows it after about a minute. Workers run the same Talos and
Kubernetes versions as the control plane and may use another instance type or
architecture.

- **Scaling down** terminates the highest-numbered workers without draining
  them. Their Node objects stay behind as `NotReady`: remove them with
  `kubectl delete node <name>`.
- **Cost:** every worker is one more instance and disk. The free-tier disk
  check only counts the control plane's disks.
- **Ingress:** Traefik runs on every node, so 80/443 also answer on the
  workers' public IPs (`terraform output worker_public_ips`). The sslip.io
  host names still point at the control plane.
- **Storage:** only the control plane has the data disk. A volume for a pod
  that runs on a worker is a directory on that worker's system disk, and it is
  lost when the worker is removed.
- **talosctl:** the published client config targets the control plane. For a
  worker add `-n <private ip>` (`terraform output worker_private_ips`).

## Add-ons

One script per add-on in [`addons/`](addons). Each is idempotent and can be
run on its own (`make traefik`, or `./addons/traefik.sh`). `make addons` and
`terraform apply` install the ones listed in `cluster.yaml`, always in the
order below. `make addons ADDONS="traefik cert-manager"` overrides the list
for one run.

Terraform runs them again when the list, a file under `addons/`, the
`Makefile` or the node's public IP changes. It only tracks that the scripts
ran, not what is installed: removing an entry does not uninstall the add-on
(`helm uninstall` does).

| Add-on | What it installs | Needs |
| ------ | ---------------- | ----- |
| `metrics-server` | `kubectl top` and HPA metrics | |
| `node-exporter` | Node metrics on port 9100 (`monitoring`) | |
| `kube-state-metrics` | Object state as Prometheus metrics (`monitoring`) | |
| `local-storage` | Default StorageClass `local-path` on the data disk | data disk |
| `prometheus` | Prometheus server, 4 Gi volume, 7 days / 3 GB retention | `local-storage` |
| `loki` | Loki (3 Gi volume, 7 days) and the Alloy collector for pod logs | `local-storage` |
| `traefik` | Ingress controller on ports 80/443 of the node, default class `traefik` | |
| `cert-manager` | Controller and CRDs | |
| `wildcard-cert` | `*.<ip>.sslip.io` certificate from a cluster-local CA, Traefik's default | `traefik`, `cert-manager` |
| `error-pages` | Catch-all 404 page; opt-in 5xx page (middleware) | `traefik` |
| `letsencrypt` | ClusterIssuers `letsencrypt-staging` / `letsencrypt-prod` (HTTP-01) | `traefik`, `cert-manager`, port 80 open |
| `hello-world` | Demo page at `https://hello.<ip>.sslip.io` | `traefik`, `letsencrypt` |
| `grafana` | Grafana at `https://grafana.<ip>.sslip.io` with Prometheus and Loki | `local-storage`, `traefik`, `letsencrypt` |

`<ip>` is the node's public IP with dashes (`52-59-83-169`).
[sslip.io](https://sslip.io) resolves such names to the IP, so no DNS record
is needed.

### Storage

All persistent volumes are directories on the data disk. Its size is the
limit for all volumes together; the size requested by a single claim is not
enforced. The defaults claim 8 of the 10 GiB (Prometheus 4, Loki 3,
Grafana 1). The data is on this one node and is destroyed with the stack.

### Certificates

- **Per host, trusted:** add the issuer annotation and a `tls` section to an
  Ingress, as `addons/hello-world.sh` does:

  ```yaml
  metadata:
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
  spec:
    ingressClassName: traefik
    tls:
      - hosts: [app.<ip>.sslip.io]
        secretName: app-tls
  ```

  Use `letsencrypt-staging` while testing: production has rate limits, and
  every new public IP means new certificates.
- **Wildcard, not publicly trusted:** hosts without their own certificate get
  the wildcard from the local CA. Let's Encrypt only issues wildcards through
  DNS-01, which needs a DNS zone you control. The CA certificate is written to
  `~/.kube/configs/<cluster name>-ca.crt`.

### Error pages

Edit the files in [`addons/error-pages/`](addons/error-pages) and run
`make error-pages`. To show `5xx.html` instead of an app's own 5xx response,
annotate its Ingress:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: traefik-error-pages@kubernetescrd
```

### Monitoring

Grafana login: user `admin`, password from

```bash
kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

Dashboards: "Node Exporter Full" and every `*.json` file in
[`addons/grafana/dashboards/`](addons/grafana/dashboards) (datasource uid
`prometheus`). Logs are under Explore with the Loki datasource.

Prometheus and Loki have no login and are not published:

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80
kubectl -n monitoring port-forward svc/loki 3100:3100
```

## Things to know

- **The public IP is ephemeral.** It changes when the instance is replaced or
  stopped and started. The API endpoint, the sslip.io host names and the
  certificates all contain it; `terraform apply` re-runs the add-ons for the
  new IP.
- **API access follows your IP.** If your own public IP changes, run
  `terraform apply` to update the security group.
- **80/443 are open to the internet** with the default `cluster.yaml`: the
  hello-world page, the 404 page and Grafana's login page are public.
- **Secrets in AWS and in state.** The Talos client config in SSM gives full
  control of the node, and `terraform.tfstate` holds the cluster secrets.
- **Small node.** With all add-ons, a `c7i-flex.large` (4 GiB) runs at about
  two thirds of its memory.
