#!/usr/bin/env bash
# Install (or upgrade) cert-manager: controller and CRDs only - no issuers are
# created here.
#
# Usage:
#   ./addons/cert-manager.sh
#
# Uses ~/.kube/configs/<cluster name>.yaml (run `make kubeconfig` first).
# Defaults can also be set via env: KUBECONFIG_DIR, CHART_VERSION.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/placement.sh
. "$STACK_DIR/addons/lib/placement.sh"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"
CHART_VERSION="${CHART_VERSION:-v1.21.2}"
NAMESPACE=cert-manager

for bin in helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run 'make kubeconfig' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

echo "==> Installing cert-manager $CHART_VERSION on '$CLUSTER'"
helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  --set crds.enabled=true \
  --set-json "nodeSelector=$CONTROL_PLANE_SELECTOR" \
  --set-json "tolerations=$CONTROL_PLANE_TOLERATIONS" \
  --set-json "webhook.nodeSelector=$CONTROL_PLANE_SELECTOR" \
  --set-json "webhook.tolerations=$CONTROL_PLANE_TOLERATIONS" \
  --set-json "cainjector.nodeSelector=$CONTROL_PLANE_SELECTOR" \
  --set-json "cainjector.tolerations=$CONTROL_PLANE_TOLERATIONS" \
  --set-json "startupapicheck.nodeSelector=$CONTROL_PLANE_SELECTOR" \
  --set-json "startupapicheck.tolerations=$CONTROL_PLANE_TOLERATIONS" \
  --wait --timeout 10m >/dev/null

kubectl -n "$NAMESPACE" get pods

# The webhook has to accept cert-manager objects before issuers can be created;
# a server-side dry run goes through it without creating anything
echo "==> Checking the cert-manager webhook"
for _ in $(seq 1 12); do
  if kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<'YAML'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: webhook-check
spec:
  selfSigned: {}
YAML
  then
    echo "cert-manager is ready (no issuers created)"
    exit 0
  fi
  sleep 5
done
echo "ERROR: cert-manager is installed but its webhook does not accept objects" >&2
exit 1
