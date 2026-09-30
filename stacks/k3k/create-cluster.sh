#!/usr/bin/env bash
# Create a k3k virtual cluster whose API server is reachable at
#   https://<name>.nginx.<ip-dashed>.sslip.io   (port 443, fully verified TLS)
#
# Traefik -> TLS passthrough -> ingress-nginx -> TLS passthrough -> k3s.
# k3s serves its own certificate (hostname in its SANs), signed by the
# cluster CA embedded in the kubeconfig, so client-certificate login works.
#
# Usage: ./create-cluster.sh <name>     (run against the host cluster context)
set -euo pipefail

NAME=${1:?usage: $0 <cluster-name>}
NS="k3k-$NAME"
CONTEXT="k3k-$NAME"
KUBECONFIG_OUT="$HOME/.kube/configs/$CONTEXT.yaml"

# Public IP as published on the ingress-nginx forwarding Gateway
IP=$(kubectl -n ingress-nginx get gateway nginx -o jsonpath='{.status.addresses[0].value}')
[ -n "$IP" ] || { echo "Could not read the public IP from gateway ingress-nginx/nginx" >&2; exit 1; }
HOST="$NAME.nginx.${IP//./-}.sslip.io"

echo "==> Creating cluster $NAME (API: https://$HOST)"
# k3kcli may report Failed while the server pod is still starting; the
# controller keeps going, so we wait for Ready ourselves.
k3kcli cluster create --tls-sans "$HOST" "$NAME" || true
kubectl -n "$NS" wait "clusters.k3k.io/$NAME" \
  --for=jsonpath='{.status.phase}'=Ready --timeout=5m

echo "==> Routing $HOST to the API server"
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api
  namespace: $NS
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
spec:
  ingressClassName: nginx
  rules:
    - host: $HOST
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: k3k-$NAME-service
                port:
                  number: 443
EOF

echo "==> Writing kubeconfig to $KUBECONFIG_OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && k3kcli kubeconfig generate "$NAME" --namespace "$NS" >/dev/null)
F="$TMP/$NS-$NAME-kubeconfig.yaml"

# Unique names (k3k uses "default" everywhere) and the public URL
sed -i -E "s/^(\s*-?\s*(name|cluster|user|current-context):) default$/\1 $CONTEXT/" "$F"
kubectl --kubeconfig "$F" config set-cluster "$CONTEXT" --server="https://$HOST" >/dev/null

mkdir -p "$(dirname "$KUBECONFIG_OUT")"
install -m 600 "$F" "$KUBECONFIG_OUT"

echo "==> Verifying (strict TLS, no skip flags)"
for i in $(seq 1 30); do
  if kubectl --kubeconfig "$KUBECONFIG_OUT" get nodes >/dev/null 2>&1; then
    kubectl --kubeconfig "$KUBECONFIG_OUT" get nodes
    echo
    echo "Done. API: https://$HOST"
    echo "Kubeconfig: $KUBECONFIG_OUT  (context $CONTEXT; open a new shell, then: kx $CONTEXT)"
    exit 0
  fi
  sleep 5
done

echo "API not reachable at https://$HOST after 150s" >&2
exit 1