#!/usr/bin/env bash
# Install (or upgrade) metrics-server: kubectl top + HPA.
# Talos kubelets serve self-signed certificates unless a serving-cert approver
# is installed, so skip verification (lab setup).
#
# Usage:
#   ./addons/metrics-server.sh
#
# Uses ~/.kube/configs/<cluster name>.yaml (run `make kubeconfig` first).
# Defaults can also be set via env: KUBECONFIG_DIR, CHART_VERSION.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"
CHART_VERSION="${CHART_VERSION:-3.14.0}"

for bin in helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run 'make kubeconfig' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

echo "==> Installing metrics-server $CHART_VERSION on '$CLUSTER'"
helm upgrade --install metrics-server metrics-server \
  --repo https://kubernetes-sigs.github.io/metrics-server \
  --version "$CHART_VERSION" \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}' \
  --wait --timeout 10m

# The metrics API answers a little after the pod is ready
echo "==> Waiting for the metrics API"
kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=120s
for _ in $(seq 1 12); do
  kubectl top nodes 2>/dev/null && exit 0
  sleep 5
done
echo "WARN: metrics-server is installed but 'kubectl top nodes' has no data yet" >&2
