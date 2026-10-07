#!/usr/bin/env bash
# Install (or upgrade) Grafana (addons/grafana/values.yaml) with Prometheus
# and Loki as datasources and the "Node Exporter Full" dashboard, and publish
# it through a Traefik Ingress at https://grafana.<node-ip-with-dashes>.sslip.io
#
# The certificate comes from the ClusterIssuer in ISSUER (default
# letsencrypt-prod, created by letsencrypt.sh). Use ISSUER=letsencrypt-staging
# while testing.
#
# Login: user admin, password generated into the "grafana" Secret:
#   kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d
#
# Usage:
#   ./addons/grafana.sh
#
# Needs a default StorageClass, Traefik, cert-manager and the Let's Encrypt
# issuers; shows data once prometheus.sh and loki.sh have run.
# Uses ~/.kube/configs/<cluster name>.yaml (run `make kubeconfig` first).
# Defaults can also be set via env: KUBECONFIG_DIR, CHART_VERSION, HOST, ISSUER.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"
CHART_VERSION="${CHART_VERSION:-13.2.8}"
ISSUER="${ISSUER:-letsencrypt-prod}"
NAMESPACE=monitoring

for bin in helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run 'make kubeconfig' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

kubectl get storageclass -o jsonpath='{.items[*].metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' | grep -q true \
  || { echo "ERROR: no default StorageClass, run 'make local-storage' first" >&2; exit 1; }
kubectl get ingressclass traefik >/dev/null 2>&1 || { echo "ERROR: Traefik is missing, run 'make traefik' first" >&2; exit 1; }
kubectl get clusterissuer "$ISSUER" >/dev/null 2>&1 || { echo "ERROR: ClusterIssuer '$ISSUER' is missing, run 'make cert-manager letsencrypt' first" >&2; exit 1; }

if [ -z "${HOST:-}" ]; then
  # The kubeconfig points at the node's public IP: https://a.b.c.d:6443
  ip="$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#^https://([^:/]+).*#\1#')"
  HOST="grafana.${ip//./-}.sslip.io"
fi

echo "==> Installing grafana $CHART_VERSION on '$CLUSTER'"
helm upgrade --install grafana grafana \
  --repo https://grafana-community.github.io/helm-charts \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$STACK_DIR/addons/grafana/values.yaml" \
  --wait --timeout 10m -f - >/dev/null <<YAML
grafana.ini:
  server:
    root_url: https://$HOST
ingress:
  enabled: true
  ingressClassName: traefik
  annotations:
    cert-manager.io/cluster-issuer: $ISSUER
  hosts:
    - $HOST
  tls:
    - secretName: grafana-tls
      hosts:
        - $HOST
YAML

echo "==> Waiting for the certificate from $ISSUER"
# cert-manager creates the Certificate a moment after the Ingress
for _ in $(seq 1 12); do
  kubectl -n "$NAMESPACE" get certificate grafana-tls >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n "$NAMESPACE" wait --for=condition=Ready certificate/grafana-tls --timeout=300s

echo "==> https://$HOST"
echo "    user admin, password: kubectl -n $NAMESPACE get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d"
