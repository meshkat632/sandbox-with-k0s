#!/usr/bin/env bash
# Deploy a "Hello, world!" page (charts/nginx-hello-world) and publish it
# through a Traefik Ingress at https://hello.<node-ip-with-dashes>.sslip.io
# (sslip.io resolves that name to the node, so no DNS record is needed).
#
# The certificate comes from the ClusterIssuer in ISSUER (default
# letsencrypt-prod, created by letsencrypt.sh). Use ISSUER=letsencrypt-staging
# while testing, or ISSUER= to serve Traefik's default wildcard certificate.
#
# Usage:
#   ./addons/hello-world.sh
#
# Needs Traefik, and cert-manager + letsencrypt.sh unless ISSUER is empty.
# Uses ~/.kube/configs/<cluster name>.yaml (run `make kubeconfig` first).
# Defaults can also be set via env: KUBECONFIG_DIR, HOST, ISSUER.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/placement.sh
. "$STACK_DIR/addons/lib/placement.sh"
CHART_DIR="$STACK_DIR/../../charts/nginx-hello-world"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"
ISSUER="${ISSUER-letsencrypt-prod}"
NAMESPACE=hello-world

for bin in helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run 'make kubeconfig' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

kubectl get ingressclass traefik >/dev/null 2>&1 || { echo "ERROR: Traefik is missing, run 'make traefik' first" >&2; exit 1; }
if [ -n "$ISSUER" ]; then
  kubectl get clusterissuer "$ISSUER" >/dev/null 2>&1 || { echo "ERROR: ClusterIssuer '$ISSUER' is missing, run 'make cert-manager letsencrypt' first" >&2; exit 1; }
fi

if [ -z "${HOST:-}" ]; then
  # The kubeconfig points at the node's public IP: https://a.b.c.d:6443
  ip="$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#^https://([^:/]+).*#\1#')"
  HOST="hello.${ip//./-}.sslip.io"
fi

echo "==> Deploying hello-world on '$CLUSTER'"
helm upgrade --install hello-world "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  --set fullnameOverride=hello-world \
  --set page.title="Hello from $CLUSTER" \
  --set page.message="Served by nginx on the $CLUSTER Talos cluster." \
  --set-json "nodeSelector=$CONTROL_PLANE_SELECTOR" \
  --set-json "tolerations=$CONTROL_PLANE_TOLERATIONS" \
  --wait --timeout 5m >/dev/null

# With an issuer, cert-manager fills the secret; without one there is no
# secret and Traefik falls back to its default certificate
if [ -n "$ISSUER" ]; then
  annotations="annotations:
    cert-manager.io/cluster-issuer: $ISSUER"
  secret="secretName: hello-world-tls"
else
  annotations="annotations: {}"
  secret=""
fi

kubectl apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-world
  namespace: $NAMESPACE
  $annotations
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - $HOST
      $secret
  rules:
    - host: $HOST
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello-world
                port:
                  number: 80
YAML

if [ -n "$ISSUER" ]; then
  echo "==> Waiting for the certificate from $ISSUER"
  # cert-manager creates the Certificate a moment after the Ingress
  for _ in $(seq 1 12); do
    kubectl -n "$NAMESPACE" get certificate hello-world-tls >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl -n "$NAMESPACE" wait --for=condition=Ready certificate/hello-world-tls --timeout=300s
fi

echo "==> https://$HOST"
