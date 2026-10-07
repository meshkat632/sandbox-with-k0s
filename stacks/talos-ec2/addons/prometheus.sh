#!/usr/bin/env bash
# Install (or upgrade) Prometheus.
# Server only: the chart's bundled kube-state-metrics, node-exporter,
# Alertmanager and Pushgateway are off. Its default scrape config picks up
# every Service annotated prometheus.io/scrape (node-exporter.sh), plus the
# API server, kubelets and cAdvisor.
#
# Data is kept on a PersistentVolume of the default StorageClass
# (local-storage.sh); retention is capped below the volume size because
# local-path does not enforce it.
#
# Not published through an Ingress (Prometheus has no login). Open it with:
#   kubectl -n monitoring port-forward svc/prometheus-server 9090:80
#
# Usage:
#   ./addons/prometheus.sh
#
# Needs a default StorageClass (make local-storage).
# Uses ~/.kube/configs/<cluster name>.yaml (run `make kubeconfig` first).
# Defaults can also be set via env: KUBECONFIG_DIR, CHART_VERSION.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/placement.sh
. "$STACK_DIR/addons/lib/placement.sh"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"
CHART_VERSION="${CHART_VERSION:-29.35.0}"
NAMESPACE=monitoring

for bin in helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run 'make kubeconfig' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

kubectl get storageclass -o jsonpath='{.items[*].metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' | grep -q true \
  || { echo "ERROR: no default StorageClass, run 'make local-storage' first" >&2; exit 1; }

echo "==> Installing prometheus $CHART_VERSION on '$CLUSTER'"
helm upgrade --install prometheus prometheus \
  --repo https://prometheus-community.github.io/helm-charts \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  --set-json "server.nodeSelector=$CONTROL_PLANE_SELECTOR" \
  --set-json "server.tolerations=$CONTROL_PLANE_TOLERATIONS" \
  --wait --timeout 10m -f - >/dev/null <<'YAML'
server:
  persistentVolume:
    enabled: true
    size: 4Gi
  retention: 7d
  retentionSize: 3GB
alertmanager:
  enabled: false
kube-state-metrics:
  enabled: false
prometheus-node-exporter:
  enabled: false
prometheus-pushgateway:
  enabled: false
YAML

kubectl -n "$NAMESPACE" get pods,pvc -l app.kubernetes.io/name=prometheus

# The first scrapes take up to a minute; ask Prometheus through the API server
echo "==> Waiting for the first scrapes"
query="/api/v1/namespaces/$NAMESPACE/services/prometheus-server:80/proxy/api/v1/query?query=count%20by%20(job)%20(up%20%3D%3D%201)"
for _ in $(seq 1 24); do
  result="$(kubectl get --raw "$query" 2>/dev/null || true)"
  if echo "$result" | grep -q '"job"'; then
    echo "Jobs with healthy targets:"
    echo "$result" | grep -o '"job":"[^"]*"' | cut -d'"' -f4 | sed 's/^/  /'
    exit 0
  fi
  sleep 5
done
echo "WARN: Prometheus is installed but reports no healthy targets yet" >&2
