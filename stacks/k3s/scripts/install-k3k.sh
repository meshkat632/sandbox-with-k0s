#!/bin/bash
# Installs / upgrades the K3k controller on the K3s node with Helm.
# Runs ON THE INSTANCE as root, via the SSM document "<name>-install-k3k".
# Inputs (exported by the SSM document): K3K_CHART_VERSION, K3K_NAMESPACE
# Idempotent: safe to run again (helm upgrade --install).
set -euo pipefail

K3K_CHART_VERSION="${K3K_CHART_VERSION:-1.2.0}"
K3K_NAMESPACE="${K3K_NAMESPACE:-k3k-system}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="$PATH:/usr/local/bin"
export HOME="${HOME:-/root}"   # helm needs a HOME for its cache/config

echo "==> waiting for K3s API"
for _ in $(seq 1 60); do
  if k3s kubectl get --raw /readyz >/dev/null 2>&1; then break; fi
  sleep 5
done
k3s kubectl get --raw /readyz >/dev/null

echo "==> checking default StorageClass"
k3s kubectl get storageclass
DEFAULT_SC="$(k3s kubectl get storageclass \
  -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')"
if [ -z "$DEFAULT_SC" ]; then
  echo "ERROR: no default StorageClass; K3k needs one" >&2
  exit 1
fi
echo "    default StorageClass: $DEFAULT_SC"

if ! command -v helm >/dev/null 2>&1; then
  echo "==> installing helm (v3)"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version --short

echo "==> installing k3k chart $K3K_CHART_VERSION into $K3K_NAMESPACE"
helm repo add k3k https://rancher.github.io/k3k --force-update
helm repo update k3k
helm upgrade --install k3k k3k/k3k \
  --namespace "$K3K_NAMESPACE" --create-namespace \
  --version "$K3K_CHART_VERSION" \
  --wait --timeout 10m

echo "==> waiting for k3k pods"
k3s kubectl -n "$K3K_NAMESPACE" wait --for=condition=Available deployment --all --timeout=300s
k3s kubectl -n "$K3K_NAMESPACE" get pods -o wide
k3s kubectl get crd | grep k3k.io
echo "==> K3k $K3K_CHART_VERSION installed"