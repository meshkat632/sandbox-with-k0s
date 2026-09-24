# codespace-k8s

Kubernetes resources inside the [codespace](../codespace) cluster, managed with
Terraform (`kubernetes` and `helm` providers):

- the namespaces in `var.namespaces` (default `apps`), labelled
  `app.kubernetes.io/managed-by=terraform`;
- the [Gateway API](https://gateway-api.sigs.k8s.io) standard CRDs
  (`gateway_api_version`), downloaded from the release and applied object by
  object;
- [Traefik](https://traefik.io) as the Gateway API controller
  (GatewayClass `traefik`, namespace `traefik`);
- the shared Gateway `gateway/public` from
  [`charts/gateway`](../../charts/gateway): a port 80 listener that redirects
  to HTTPS, and one HTTPS listener per hostname (`https-<key>`, certificate in
  secret `<key>-tls`);
- [cert-manager](https://cert-manager.io) with Gateway API support, and the
  ClusterIssuers `letsencrypt-staging` / `letsencrypt-prod` from
  [`charts/letsencrypt-issuers`](../../charts/letsencrypt-issuers), which solve
  HTTP-01 with an HTTPRoute on the Gateway's port 80 listener;
- `nginx-hello-world`, a static page from
  [`charts/nginx-hello-world`](../../charts/nginx-hello-world) in `apps`,
  attached to the `https-hello` listener by an HTTPRoute and served at
  `hello_url` (by default `https://hello.<ip-with-dashes>.sslip.io`, which
  resolves to the Elastic IP with no DNS setup).

Any edit to a local chart's files triggers a Helm upgrade on the next apply.

## Adding an app

1. Add its hostname to `hosts` of `helm_release.gateway` (e.g.
   `api = "api.<ip-with-dashes>.sslip.io"`). cert-manager issues the
   `api-tls` certificate for the new `https-api` listener.
2. Deploy the app in one of `var.namespaces` with an HTTPRoute whose
   `parentRefs` is `{name: public, namespace: gateway, sectionName: https-api}`.

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
| `gateway_api_version`    | `v1.5.1`               | Gateway API CRDs release (one Traefik supports)     |
| `traefik_chart_version`  | `41.6.0`               | Traefik Helm chart version                          |
| `cert_manager_chart_version` | `v1.21.2`          | cert-manager Helm chart version                     |
| `letsencrypt_email`      | `meshkat632@gmail.com` | Let's Encrypt account email                         |
| `letsencrypt_environment`| `prod`                 | `staging` or `prod` issuer for the hello-world cert |
| `hello_host`             | `null` (sslip.io name) | Hostname of hello-world; must resolve to the EIP    |

## Outputs

`namespaces`, `cluster_endpoint`, `gateway` (name, namespace, address), `hello_url`.

## Notes

- Traefik runs as a DaemonSet bound to ports 80/443 of the instance
  (hostPort; there is no cloud load balancer, so its Service is ClusterIP).
  Its entry points listen on 8000/8443 inside the pod, which is why the
  Gateway's listeners use those ports. The codespace stack's security group
  opens 80/443 to its `web_allowed_cidrs`.
- Let's Encrypt must reach port 80 for HTTP-01, so narrowing
  `web_allowed_cidrs` stops certificate issuance and renewal. Try new
  hostnames with `letsencrypt_environment = "staging"` first: production has
  strict rate limits. Only listener hostnames are served; the bare IP gets
  no route.
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
