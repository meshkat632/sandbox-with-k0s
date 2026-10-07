#!/usr/bin/env bash
# Create the Let's Encrypt ClusterIssuers letsencrypt-staging and
# letsencrypt-prod (charts/letsencrypt-issuers). They solve the HTTP-01
# challenge through Traefik, so port 80 must be reachable from the internet:
# spec.infrastructure.network.httpIngress.allowedCIDRBlocks in cluster.yaml.
#
# An Ingress gets its own trusted certificate with:
#   metadata.annotations:  cert-manager.io/cluster-issuer: letsencrypt-prod
#   spec.tls:              [{hosts: [<host>], secretName: <host>-tls}]
#
# HTTP-01 issues one certificate per hostname - no wildcards. The wildcard from
# wildcard-cert.sh stays the default for hosts without their own certificate.
# Try letsencrypt-staging first: production has strict rate limits.
#
# Usage:
#   ./addons/letsencrypt.sh
#
# Needs cert-manager and Traefik (make cert-manager traefik).
# Uses ~/.kube/configs/<cluster name>.yaml (run `make kubeconfig` first).
# Defaults can also be set via env: KUBECONFIG_DIR, LETSENCRYPT_EMAIL
# (account email for expiry notices, default: git config user.email).
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHART_DIR="$STACK_DIR/../../charts/letsencrypt-issuers"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"
EMAIL="${LETSENCRYPT_EMAIL:-$(git -C "$STACK_DIR" config user.email || true)}"

for bin in helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run 'make kubeconfig' first" >&2; exit 1; }
[ -n "$EMAIL" ] || { echo "ERROR: set LETSENCRYPT_EMAIL (no git user.email found)" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1 || { echo "ERROR: cert-manager is missing, run 'make cert-manager' first" >&2; exit 1; }
kubectl get ingressclass traefik >/dev/null 2>&1 || { echo "ERROR: Traefik is missing, run 'make traefik' first" >&2; exit 1; }

echo "==> Let's Encrypt issuers on '$CLUSTER' (account $EMAIL)"
helm upgrade --install letsencrypt-issuers "$CHART_DIR" \
  --namespace cert-manager \
  --set email="$EMAIL" \
  --set solver=ingress \
  --set ingressClassName=traefik \
  --wait >/dev/null

# Ready = the ACME account is registered with Let's Encrypt
kubectl wait --for=condition=Ready clusterissuer/letsencrypt-staging clusterissuer/letsencrypt-prod --timeout=120s
kubectl get clusterissuer
