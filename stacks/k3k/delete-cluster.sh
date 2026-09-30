#!/usr/bin/env bash
# Delete a k3k virtual cluster created by create-cluster.sh, including its
# namespace (API Ingress, PVC) and local kubeconfig.
#
# Usage: ./delete-cluster.sh <name>     (run against the host cluster context)
set -euo pipefail

NAME=${1:?usage: $0 <cluster-name>}
NS="k3k-$NAME"

k3kcli cluster delete "$NAME" --namespace "$NS" || true
kubectl delete namespace "$NS" --ignore-not-found --wait=true
rm -f "$HOME/.kube/configs/k3k-$NAME.yaml"

echo "Deleted cluster $NAME"