#!/usr/bin/env bash
# Fetch a kubeconfig for every k3k virtual cluster on the host cluster and
# store it in ~/.kube/configs/k3k-<name>.yaml (context k3k-<name>), so that
# `kx` can switch to each of them. Kubeconfigs of clusters that no longer
# exist are removed.
#
# The API URL is the host of the cluster's passthrough Ingress "api" (created
# by create-cluster.sh). Clusters without it keep k3kcli's default NodePort
# URL and are reported, since that endpoint is usually not reachable.
#
# Usage: ./sync-kubeconfigs.sh [--force]   (run against the host cluster context)
#   --force   regenerate kubeconfigs even when the existing one still works
set -euo pipefail

FORCE=false
[ "${1:-}" = "--force" ] && FORCE=true

CONFIG_DIR="$HOME/.kube/configs"
mkdir -p "$CONFIG_DIR"

HOST_CONTEXT=$(kubectl config current-context)
echo "Host cluster: $HOST_CONTEXT"
echo

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

declare -A KEEP=()
ok=0 skipped=0 warn=0

while read -r NS NAME; do
  [ -n "$NAME" ] || continue

  # Context name: k3k-<name>, or k3k-<namespace>-<name> for clusters outside
  # the k3kcli default namespace (keeps names unique)
  if [ "$NS" = "k3k-$NAME" ]; then CONTEXT="k3k-$NAME"; else CONTEXT="k3k-$NS-$NAME"; fi
  OUT="$CONFIG_DIR/$CONTEXT.yaml"
  KEEP["$OUT"]=1

  PHASE=$(kubectl -n "$NS" get "clusters.k3k.io/$NAME" -o jsonpath='{.status.phase}')
  if [ "$PHASE" != "Ready" ]; then
    echo "!  $CONTEXT: cluster phase is '$PHASE', skipped"
    warn=$((warn + 1))
    continue
  fi

  HOST=$(kubectl -n "$NS" get ingress api -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)
  SERVER=${HOST:+https://$HOST}

  # Keep a working kubeconfig that already points at the right URL
  if ! $FORCE && [ -f "$OUT" ] && [ -n "$SERVER" ] \
     && [ "$(kubectl --kubeconfig "$OUT" config view -o jsonpath='{.clusters[0].cluster.server}')" = "$SERVER" ] \
     && kubectl --kubeconfig "$OUT" get --raw /readyz >/dev/null 2>&1; then
    echo "=  $CONTEXT: up to date ($SERVER)"
    skipped=$((skipped + 1))
    continue
  fi

  rm -f "$TMP"/*.yaml
  (cd "$TMP" && k3kcli kubeconfig generate "$NAME" --namespace "$NS" >/dev/null 2>&1)
  F=$(ls "$TMP"/*.yaml)

  sed -i -E "s/^(\s*-?\s*(name|cluster|user|current-context):) default$/\1 $CONTEXT/" "$F"
  if [ -n "$SERVER" ]; then
    kubectl --kubeconfig "$F" config set-cluster "$CONTEXT" --server="$SERVER" >/dev/null
  fi
  install -m 600 "$F" "$OUT"

  if [ -z "$SERVER" ]; then
    echo "!  $CONTEXT: no 'api' Ingress, using NodePort URL (create one to get https://<name>.nginx...)"
    warn=$((warn + 1))
  elif kubectl --kubeconfig "$OUT" get --raw /readyz >/dev/null 2>&1; then
    echo "+  $CONTEXT: written ($SERVER)"
    ok=$((ok + 1))
  else
    echo "!  $CONTEXT: written, but $SERVER is not reachable yet"
    warn=$((warn + 1))
  fi
done < <(kubectl get clusters.k3k.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}')

# Remove kubeconfigs of deleted clusters (only files this script manages)
for f in "$CONFIG_DIR"/k3k-*.yaml; do
  [ -e "$f" ] || continue
  if [ -z "${KEEP[$f]:-}" ]; then
    rm -f "$f"
    echo "-  $(basename "$f" .yaml): cluster no longer exists, removed"
  fi
done

echo
echo "Done: $ok written, $skipped up to date, $warn with warnings."
echo "Open a new shell (or: source ~/.zshrc) so KUBECONFIG picks up the files, then run kx."