#!/usr/bin/env bash
# Install (or upgrade) Traefik as the default ingress class "traefik".
# No cloud load balancer here, so Traefik runs on the node and binds ports
# 80/443 there (hostPort). Talos enforces the "baseline" pod security level,
# which forbids host ports - the namespace has to be privileged.
#
# Usage:
#   ./addons/traefik.sh
#
# Uses ~/.kube/configs/<cluster name>.yaml (run `make kubeconfig` first).
# Defaults can also be set via env: KUBECONFIG_DIR, CHART_VERSION.
#
# Who can reach 80/443 is set in cluster.yaml
# (spec.infrastructure.network.httpIngress.allowedCIDRBlocks) + terraform apply.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/placement.sh
. "$STACK_DIR/addons/lib/placement.sh"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"
CHART_VERSION="${CHART_VERSION:-41.6.1}"
NAMESPACE=traefik

for bin in helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run 'make kubeconfig' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

echo "==> Namespace '$NAMESPACE' (privileged pod security, needed for host ports)"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite

# maxSurge=0: a second pod can't start while the old one holds the host ports
echo "==> Installing traefik $CHART_VERSION on '$CLUSTER'"
helm upgrade --install traefik traefik \
  --repo https://traefik.github.io/charts \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --set deployment.kind=DaemonSet \
  --set updateStrategy.rollingUpdate.maxUnavailable=1 \
  --set updateStrategy.rollingUpdate.maxSurge=0 \
  --set ports.web.hostPort=80 \
  --set ports.websecure.hostPort=443 \
  --set service.type=ClusterIP \
  --set ingressClass.enabled=true \
  --set ingressClass.isDefaultClass=true \
  --set-json "tolerations=$ALL_NODES_TOLERATIONS" \
  --wait --timeout 10m >/dev/null

kubectl -n "$NAMESPACE" get pods -o wide
kubectl get ingressclass
echo "==> Listening on ports 80/443 of the node (reachable only from allowedCIDRBlocks in cluster.yaml)"
