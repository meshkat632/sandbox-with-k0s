#!/usr/bin/env bash
# Issue a wildcard certificate and make it Traefik's default certificate, so
# every HTTPS host under the domain is served with it.
#
# The domain defaults to <node-ip-with-dashes>.sslip.io: sslip.io resolves
# anything.<a-b-c-d>.sslip.io to a.b.c.d, so no DNS record is needed.
#
# The certificate is signed by a CA that lives in this cluster ("local-ca").
# Let's Encrypt only issues wildcards through a DNS-01 challenge, which needs a
# DNS zone we control - sslip.io is not ours. Browsers therefore warn until the
# CA is trusted on your machine; the script writes it next to the kubeconfig.
#
# Usage:
#   ./addons/wildcard-cert.sh
#
# Needs cert-manager and Traefik (./addons.sh cert-manager traefik).
# Uses ~/.kube/configs/<cluster name>.yaml (run `./kubeconfig.sh` first).
# Defaults can also be set via env: KUBECONFIG_DIR, DOMAIN.
#
# The node's public IP changes when the instance is replaced: run this again.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_DIR="${KUBECONFIG_DIR:-$HOME/.kube/configs}"
KUBECONFIG_FILE="$KUBECONFIG_DIR/$CLUSTER.yaml"
CA_FILE="$KUBECONFIG_DIR/$CLUSTER-ca.crt"

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: 'kubectl' not found in PATH" >&2; exit 1; }
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run './kubeconfig.sh' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

for crd in certificates.cert-manager.io tlsstores.traefik.io; do
  kubectl get crd "$crd" >/dev/null 2>&1 || { echo "ERROR: $crd is missing, run './addons.sh cert-manager traefik' first" >&2; exit 1; }
done

if [ -z "${DOMAIN:-}" ]; then
  # The kubeconfig points at the node's public IP: https://a.b.c.d:6443
  ip="$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#^https://([^:/]+).*#\1#')"
  DOMAIN="${ip//./-}.sslip.io"
fi

echo "==> Wildcard certificate for *.$DOMAIN on '$CLUSTER'"
kubectl apply -f - <<YAML
# Self-signed issuer, only used to create the CA below
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: local-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: $CLUSTER local CA
  secretName: local-ca
  duration: 87600h # 10 years
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
---
# Signs certificates with the CA; usable from any namespace
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: local-ca
spec:
  ca:
    secretName: local-ca
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard
  namespace: traefik
spec:
  secretName: wildcard-tls
  dnsNames:
    - "*.$DOMAIN"
    - "$DOMAIN"
  issuerRef:
    name: local-ca
    kind: ClusterIssuer
---
# Traefik serves this certificate for every HTTPS host without its own one
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: traefik
spec:
  defaultCertificate:
    secretName: wildcard-tls
YAML

kubectl -n cert-manager wait --for=condition=Ready certificate/local-ca --timeout=120s
kubectl -n traefik wait --for=condition=Ready certificate/wildcard --timeout=120s

kubectl -n traefik get secret wildcard-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA_FILE"
echo "==> https://<anything>.$DOMAIN is served with the wildcard certificate"
echo "    CA certificate: $CA_FILE (trust it, or use: curl --cacert $CA_FILE ...)"
