#!/usr/bin/env bash
# Install (or upgrade) Loki and the Grafana Alloy log collector.
#
#   - Loki (addons/loki/values.yaml): one pod, logs on a PersistentVolume of
#     the default StorageClass, deleted after 7 days.
#   - Alloy (addons/loki/config.alloy): reads the logs of every pod through
#     the Kubernetes API and pushes them to Loki, labelled with namespace,
#     pod, container, app and node.
#
# Loki has no login and is not published through an Ingress. Browse the logs
# in Grafana (grafana.sh), or query it directly:
#   kubectl -n monitoring port-forward svc/loki 3100:3100
#
# Usage:
#   ./addons/loki.sh
#
# Needs a default StorageClass (make local-storage).
# Uses ~/.kube/configs/<cluster name>.yaml (run `make kubeconfig` first).
# Defaults can also be set via env: KUBECONFIG_DIR, LOKI_CHART_VERSION,
# ALLOY_CHART_VERSION.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$STACK_DIR/addons/loki"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-18.13.8}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.13.0}"
NAMESPACE=monitoring

for bin in helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run 'make kubeconfig' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

kubectl get storageclass -o jsonpath='{.items[*].metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' | grep -q true \
  || { echo "ERROR: no default StorageClass, run 'make local-storage' first" >&2; exit 1; }

echo "==> Installing loki $LOKI_CHART_VERSION on '$CLUSTER'"
helm upgrade --install loki loki \
  --repo https://grafana-community.github.io/helm-charts \
  --version "$LOKI_CHART_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$CONFIG_DIR/values.yaml" \
  --wait --timeout 10m >/dev/null

echo "==> Installing alloy $ALLOY_CHART_VERSION"
helm upgrade --install alloy alloy \
  --repo https://grafana.github.io/helm-charts \
  --version "$ALLOY_CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --set-file alloy.configMap.content="$CONFIG_DIR/config.alloy" \
  --wait --timeout 10m >/dev/null

kubectl -n "$NAMESPACE" get pods -l 'app.kubernetes.io/name in (loki, alloy)'

# Logs arrive a few seconds after Alloy starts; ask Loki through the API server
echo "==> Waiting for the first logs"
for _ in $(seq 1 24); do
  namespaces="$(kubectl get --raw "/api/v1/namespaces/$NAMESPACE/services/loki:3100/proxy/loki/api/v1/label/namespace/values" 2>/dev/null || true)"
  if echo "$namespaces" | grep -q '"data":\["'; then
    echo "Loki has logs from namespaces: $(echo "$namespaces" | sed -E 's/.*"data":\[([^]]*)\].*/\1/' | tr -d '"' | sed 's/,/, /g')"
    exit 0
  fi
  sleep 5
done
echo "WARN: Loki and Alloy are installed but no logs have arrived yet" >&2
