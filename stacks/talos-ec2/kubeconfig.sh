#!/usr/bin/env bash
# Fetch the admin kubeconfig from the cluster and write it to
# ~/.kube/configs/<cluster name>.yaml (one cluster per file, picked up by
# kubectl from ~/.kube/configs/*.yaml), then wait for the API server.
#
# It does not run Terraform or read its state: the cluster name and region
# come from cluster.yaml, the Talos client config from SSM Parameter Store.
# Talos has no SSH: the node hands out a fresh kubeconfig over its API (50000).
#
# Usage:
#   ./kubeconfig.sh
#
# Defaults can also be set via env: KUBECONFIG_DIR, WAIT_SECONDS (how long to
# wait for the API server, default 300), TALOSCTL, TALOSCONFIG_PARAM.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")" && pwd)"
CLUSTER="$(sed -n 's/^  name: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
REGION="$(sed -n 's/^ *region: *//p' "$STACK_DIR/cluster.yaml" | head -1)"
KUBECONFIG_DIR="${KUBECONFIG_DIR:-$HOME/.kube/configs}"
KUBECONFIG_OUT="$KUBECONFIG_DIR/$CLUSTER.yaml"
WAIT_SECONDS="${WAIT_SECONDS:-300}"
TALOSCTL="${TALOSCTL:-talosctl}"
TALOSCONFIG_PARAM="${TALOSCONFIG_PARAM:-/talos/$CLUSTER/talosconfig}"

for bin in aws "$TALOSCTL" kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

aws ssm get-parameter --region "$REGION" --name "$TALOSCONFIG_PARAM" --with-decryption \
  --query Parameter.Value --output text > "$tmp/talosconfig"
"$TALOSCTL" --talosconfig "$tmp/talosconfig" kubeconfig "$tmp/kubeconfig" --merge=false

mkdir -p "$KUBECONFIG_DIR"
install -m 600 "$tmp/kubeconfig" "$KUBECONFIG_OUT"
echo "Wrote $KUBECONFIG_OUT"

# Right after an apply the node is still starting the control plane
echo "Waiting for the API server (up to ${WAIT_SECONDS}s)"
deadline=$(( $(date +%s) + WAIT_SECONDS ))
until kubectl --kubeconfig "$KUBECONFIG_OUT" --request-timeout=5s get --raw /readyz >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ERROR: API server not ready after ${WAIT_SECONDS}s" >&2
    kubectl --kubeconfig "$KUBECONFIG_OUT" --request-timeout=5s get --raw /readyz >&2 || true
    exit 1
  fi
  sleep 5
done
echo "API server is ready"
