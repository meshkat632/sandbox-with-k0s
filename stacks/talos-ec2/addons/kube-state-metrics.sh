#!/usr/bin/env bash
# Install (or upgrade) kube-state-metrics: the state of Kubernetes objects
# (deployments, pods, nodes, volumes, ...) as Prometheus metrics on port 8080.
#
# Its Service carries prometheus.io/scrape, which is how Prometheus
# (prometheus.sh) finds it.
#
# Usage:
#   ./addons/kube-state-metrics.sh
#
# Uses ~/.kube/configs/<cluster name>.yaml (run `make kubeconfig` first).
# Defaults can also be set via env: KUBECONFIG_DIR, CHART_VERSION.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/placement.sh
. "$STACK_DIR/addons/lib/placement.sh"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"
CHART_VERSION="${CHART_VERSION:-8.6.0}"
NAMESPACE=monitoring

for bin in helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run 'make kubeconfig' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

echo "==> Installing kube-state-metrics $CHART_VERSION on '$CLUSTER'"
helm upgrade --install kube-state-metrics kube-state-metrics \
  --repo https://prometheus-community.github.io/helm-charts \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  --set-json "nodeSelector=$CONTROL_PLANE_SELECTOR" \
  --set-json "tolerations=$CONTROL_PLANE_TOLERATIONS" \
  --wait --timeout 10m >/dev/null

kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=kube-state-metrics

# Read a few metrics through the API server, as a scraper would see them
echo "==> Checking /metrics"
kubectl get --raw "/api/v1/namespaces/$NAMESPACE/services/kube-state-metrics:8080/proxy/metrics" \
  | grep -E '^kube_(node_info|namespace_created)' | cut -c1-120
