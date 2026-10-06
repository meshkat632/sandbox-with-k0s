#!/usr/bin/env bash
# Copy the cluster's admin kubeconfig to $KUBECONFIG_DIR/<cluster name>.yaml
# (one file per cluster) and print the path.
set -euo pipefail

KUBECONFIG_DIR="${KUBECONFIG_DIR:-$HOME/.kube/configs}"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
terraform output -raw kubeconfig > "$tmp"

name=$(kubectl --kubeconfig "$tmp" config view -o jsonpath='{.clusters[0].name}')
mkdir -p "$KUBECONFIG_DIR"
install -m 600 "$tmp" "$KUBECONFIG_DIR/$name.yaml"
echo "$KUBECONFIG_DIR/$name.yaml"
