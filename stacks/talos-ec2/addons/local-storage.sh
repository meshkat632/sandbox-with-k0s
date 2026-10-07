#!/usr/bin/env bash
# Install the default StorageClass "local-path" (local-path-provisioner).
# Volumes are directories on the node's data disk, which has a fixed size:
# spec.controlPlane.machineTemplate.spec.dataVolume.size in cluster.yaml.
# Terraform attaches the disk and Talos mounts it at /var/mnt/local-storage.
#
# The disk size is the limit for all volumes together. The size requested by a
# single PersistentVolumeClaim is not enforced, and the data lives on this one
# node only.
#
# Usage:
#   ./addons/local-storage.sh
#
# Uses ~/.kube/configs/<cluster name>.yaml (run `make kubeconfig` first).
# Defaults can also be set via env: KUBECONFIG_DIR.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_FILE="${KUBECONFIG_DIR:-$HOME/.kube/configs}/$CLUSTER.yaml"

# kubectl builds the kustomization, whose base is fetched with git
for bin in kubectl git; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$KUBECONFIG_FILE" ] || { echo "ERROR: $KUBECONFIG_FILE not found, run 'make kubeconfig' first" >&2; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"

# Without the data disk the volumes would silently fill the system disk
size="$(sed -n '/^ *dataVolume:/,/size:/s/^ *size: *\([0-9]*\).*/\1/p' "$STACK_DIR/cluster.yaml" | head -1)"
if [ "${size:-0}" -eq 0 ]; then
  echo "ERROR: no data disk: set dataVolume.size in cluster.yaml and run terraform apply" >&2
  exit 1
fi

echo "==> Installing local-path-provisioner on '$CLUSTER' (${size} GiB data disk)"
kubectl apply -k "$STACK_DIR/addons/local-storage"
kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=180s
kubectl get storageclass
