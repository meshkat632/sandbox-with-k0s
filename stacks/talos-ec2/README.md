# talos-ec2

A [Talos](https://www.talos.dev) Kubernetes cluster on EC2. By default it is
one instance sized to fit the AWS free tier. Optionally it has three control
plane nodes behind a Network Load Balancer, and extra worker nodes. Every node
is tainted: a pod only runs where it explicitly asks to (see
[Scheduling](#scheduling)).

Everything is configured in one file, [`cluster.yaml`](cluster.yaml), a
CAPI-style `Cluster` object. `terraform apply` creates:

- a security group in the default VPC: the Talos API (50000) and the
  Kubernetes API (6443) are open to **your current public IP only**; 80/443
  are open to `httpIngress.allowedCIDRBlocks`; nodes reach each other freely;
- `controlPlane.replicas` EC2 instances from the official Talos AMI, each
  with an ephemeral public IP;
- a separate gp3 data disk per control plane node (`dataVolume.size`), which
  Talos mounts at `/var/mnt/local-storage` for persistent volumes;
- optionally a Network Load Balancer with a fixed public IP for the
  Kubernetes API and for HTTP/HTTPS (`controlPlaneLoadBalancer.enabled`);
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
| `spec.infrastructure.controlPlaneLoadBalancer.enabled` | Network Load Balancer for 6443, 80 and 443 (see below) |
| `spec.controlPlane.replicas` | Control plane nodes: 1, 3 or 5. More than 1 needs the load balancer |
| `spec.controlPlane.version` | Kubernetes version |
| `spec.controlPlane.machineTemplate.spec.instanceType` | One of the free-tier types that can run Talos (listed in the file) |
| `...rootVolume.size` / `...dataVolume.size` | Disk sizes in GiB per node; with a single node together at most 30. `dataVolume.size: 0` = no data disk |
| `spec.controlPlane.controlPlaneConfig.talosVersion` | Exact Talos release (AMI and installer) |
| `spec.controlPlane.controlPlaneConfig.strategicPatches` | Optional extra Talos machine-config patches |
| `spec.workers.replicas` | Number of extra worker nodes; `0` = single node |
| `spec.workers.machineTemplate.spec` | `instanceType` and `rootVolume.size` of the workers |
| `spec.addons.install` | Add-ons to install (see below) |

The plan fails on a non-free-tier instance type, more than 30 GiB of disk on a
single node, an even number of control plane nodes, several of them without
the load balancer, or an unknown add-on name.

## Highly available control plane

```yaml
spec:
  infrastructure:
    controlPlaneLoadBalancer:
      enabled: true
  controlPlane:
    replicas: 3
```

- **Control plane:** three nodes with the same config. Terraform bootstraps
  the first; the others join its etcd. One node may fail without losing the
  API or etcd.
- **Load balancer:** a Network Load Balancer with one Elastic IP
  (`terraform output load_balancer_ip`). Port 6443 goes to the control plane
  nodes, 80/443 to every node, where Traefik listens. The API endpoint in the
  kubeconfig and the sslip.io host names are built from this IP, so they
  survive a node replacement.
- **Access:** 6443 on the load balancer is open to your IP and to the nodes;
  80/443 to `httpIngress.allowedCIDRBlocks`. The Talos API is not load
  balanced: `talosctl` uses the nodes' own public IPs
  (`terraform output control_plane_public_ips`).
- **Failover takes about 10 seconds.** Until the health check notices a dead
  node, connections that land on it fail; clients have to retry.
- **One availability zone.** All nodes and the load balancer are in one
  subnet. It survives a node failure, not a zone failure.
- **Client addresses are hidden.** Traefik sees the load balancer's address,
  not the visitor's.
- **Storage is still per node.** Every control plane node has its own data
  disk, and a volume lives on one node: the API is highly available, an app
  with a volume is not.
- **Cost:** not free tier - three instances, 90 GiB of disk with the default
  sizes, and the load balancer (roughly $16-20 a month plus traffic).
- **Do not lower `replicas` on a running cluster.** The removed nodes are
  terminated without leaving etcd, and going from 3 to 1 loses the majority.
  Rebuild instead, or remove the members first with `talosctl`.
- **Switching an existing single-node cluster** changes the API endpoint, so
  the node is reconfigured and the kubeconfig and host names change. Treat it
  as a rebuild.

The load balancer also works with `replicas: 1`, to get the fixed IP.

## Scheduling

No node accepts pods by default. Each has a label to select it and a taint
that keeps everything else away:

| Nodes | Label | Taint |
| ----- | ----- | ----- |
| Control plane | `cluster.local/role=control-plane` (and `node-role.kubernetes.io/control-plane`) | `node-role.kubernetes.io/control-plane:NoSchedule` |
| Workers | `cluster.local/role=worker` | `cluster.local/role=worker:NoSchedule` |

A pod needs **both** a toleration and a node selector. The toleration lets it
onto the tainted nodes; the selector keeps it off the others. A node selector
alone leaves the pod `Pending`.

```yaml
# on the workers
spec:
  nodeSelector:
    cluster.local/role: worker
  tolerations:
    - key: cluster.local/role
      operator: Equal
      value: worker
      effect: NoSchedule
```

```yaml
# on the control plane
spec:
  nodeSelector:
    cluster.local/role: control-plane
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
```

The add-ons place themselves ([`addons/lib/placement.sh`](addons/lib/placement.sh)):
cluster services run on the control plane nodes; Traefik, the node exporter
and the Alloy log collector run on every node. Kubernetes' own pods (CoreDNS,
flannel, kube-proxy) tolerate the taints already.

The taints are `NoSchedule`: pods that were already running when a node got
its taint keep running until they are rescheduled.

## Worker nodes

Set `spec.workers.replicas` in `cluster.yaml` and run `terraform apply`. Each
worker ([`modules/workers`](modules/workers)) is an instance from the Talos AMI
that gets a worker config and joins through the load balancer, or through the
control plane's private IP without one;
`make nodes` shows it after about a minute. Workers run the same Talos and
Kubernetes versions as the control plane and may use another instance type or
architecture.

- **Scaling down** terminates the highest-numbered workers without draining
  them. Their Node objects stay behind as `NotReady`: remove them with
  `kubectl delete node <name>`.
- **Cost:** every worker is one more instance and disk. The free-tier disk
  check only counts the control plane's disks.
- **Ingress:** Traefik runs on every node. With the load balancer, workers
  are HTTP/HTTPS targets too. Without it, 80/443 also answer on the workers'
  public IPs (`terraform output worker_public_ips`), while the sslip.io host
  names point at the control plane.
- **Storage:** only control plane nodes have a data disk. A volume for a pod
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

`<ip>` is the load balancer's IP, or without one the node's public IP, with
dashes (`52-59-83-169`).
[sslip.io](https://sslip.io) resolves such names to the IP, so no DNS record
is needed.

### Storage

All persistent volumes are directories on the data disk of the node the pod
runs on. Its size is the limit for all volumes on that node; the size
requested by a single claim is not enforced. The defaults claim 8 of the 10 GiB (Prometheus 4, Loki 3,
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

- **Without the load balancer, the public IP is ephemeral.** It changes when
  the instance is replaced or stopped and started. The API endpoint, the
  sslip.io host names and the certificates all contain it; `terraform apply`
  re-runs the add-ons for the new IP.
- **API access follows your IP.** If your own public IP changes, run
  `terraform apply` to update the security group.
- **80/443 are open to the internet** with the default `cluster.yaml`: the
  hello-world page, the 404 page and Grafana's login page are public.
- **Secrets in AWS and in state.** The Talos client config in SSM gives full
  control of the node, and `terraform.tfstate` holds the cluster secrets.
- **Small node.** With all add-ons, a `c7i-flex.large` (4 GiB) runs at about
  two thirds of its memory.
