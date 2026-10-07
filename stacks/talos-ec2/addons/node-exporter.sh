#!/usr/bin/env bash
# Install (or upgrade) the Prometheus node exporter: CPU, memory, disk and
# network metrics of the node on port 9100 (/metrics).
# It reads the host's /proc, /sys and root filesystem and uses the host
# network. Talos enforces the "baseline" pod security level, which forbids
# that - the namespace has to be privileged.
#
# Its Service carries prometheus.io/scrape, which is how a Prometheus with
# annotation-based discovery finds it. This script does not install Prometheus.
#
# Usage:
#   ./addons/node-exporter.sh
#
# Uses ~/.kube/configs/<cluster name>.yaml (run `make kubeconfig` first).
# Defaults can also be set via env: KUBECONFIG_DIR, CHART_VERSION.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"
CHART_VERSION="${CHART_VERSION:-4.59.0}"
NAMESPACE=monitoring

for bin in helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run 'make kubeconfig' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

echo "==> Namespace '$NAMESPACE' (privileged pod security, needed for host access)"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite

echo "==> Installing node-exporter $CHART_VERSION on '$CLUSTER'"
helm upgrade --install node-exporter prometheus-node-exporter \
  --repo https://prometheus-community.github.io/helm-charts \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --set fullnameOverride=node-exporter \
  --wait --timeout 10m >/dev/null

kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=prometheus-node-exporter -o wide

# Read a few metrics through the API server, as a scraper would see them
echo "==> Checking /metrics"
kubectl get --raw "/api/v1/namespaces/$NAMESPACE/services/node-exporter:metrics/proxy/metrics" \
  | grep -E '^node_(load1|memory_MemAvailable_bytes|uname_info)'
