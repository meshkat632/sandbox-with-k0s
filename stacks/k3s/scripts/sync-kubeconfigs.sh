#!/usr/bin/env bash
# Generate kubeconfigs for K3k virtual clusters with k3kcli and store each one as
# its own file in ~/.kube/configs/ (one cluster per file, mode 0600).
#
#   - no NAME:  every virtual cluster on the host (all namespaces, all modes)
#   - NAME:     just that cluster
#
# Each file gets unique names (context/cluster/user = k3k-<name>, or k3k-<ns>-<name>,
# when the same name exists in several namespaces), so kubectx and Lens never mix
# up credentials. The server address is the host's CURRENT public address, taken
# from the host kubeconfig, so re-running after an IP change fixes all files.
#
# Usage:
#   ./scripts/hcp-kubeconfig.sh [NAME] [-n NAMESPACE] [-H HOST_KUBECONFIG] [-s SERVER] [-d DIR] [--prune]
#
#   -n NAMESPACE  namespace of NAME (default: looked up), or limit the "all" run to it
#   -H FILE       kubeconfig of the HOST cluster (default ~/.kube/configs/k3k-host.yaml)
#   -s SERVER     public IP/DNS of the host     (default: from the -H kubeconfig)
#   -d DIR        output folder                 (default ~/.kube/configs)
#   --prune       delete files written by this script for clusters that no longer exist
set -euo pipefail

NAME=""
NAMESPACE=""
HOST_KCFG="$HOME/.kube/configs/k3k-host.yaml"
SERVER_HOST=""
OUT_DIR="$HOME/.kube/configs"
PRUNE=0
MARKER="# generated-by: hcp-kubeconfig.sh"

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -H|--host)      HOST_KCFG="$2"; shift 2 ;;
    -s|--server)    SERVER_HOST="$2"; shift 2 ;;
    -d|--dir)       OUT_DIR="$2"; shift 2 ;;
    --prune)        PRUNE=1; shift ;;
    -h|--help)      usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *)  NAME="$1"; shift ;;
  esac
done

for bin in k3kcli kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done
[ -s "$HOST_KCFG" ] || { echo "ERROR: host kubeconfig $HOST_KCFG not found" >&2; exit 1; }
HOST_KCFG="$(cd "$(dirname "$HOST_KCFG")" && pwd)/$(basename "$HOST_KCFG")"
hk() { kubectl --kubeconfig "$HOST_KCFG" --request-timeout=15s "$@"; }

# Current public address of the host = host API server address in its kubeconfig
if [ -z "$SERVER_HOST" ]; then
  url="$(kubectl --kubeconfig "$HOST_KCFG" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  SERVER_HOST="${url#*://}"; SERVER_HOST="${SERVER_HOST%%:*}"; SERVER_HOST="${SERVER_HOST%%/*}"
fi
[ -n "$SERVER_HOST" ] || { echo "ERROR: could not determine the host address; pass -s" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

# --- which clusters? ("<namespace> <name> <mode> <phase>" per line) -------------
if ! hk get clusters.k3k.io -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.mode}{" "}{.status.phase}{"\n"}{end}' \
      >"$TMP/all.txt" 2>"$TMP/err"; then
  echo "ERROR: cannot list virtual clusters on the host:" >&2; cat "$TMP/err" >&2; exit 1
fi
awk -v n="$NAME" -v ns="$NAMESPACE" '($2 == n || n == "") && ($1 == ns || ns == "")' "$TMP/all.txt" >"$TMP/sel.txt"

if [ ! -s "$TMP/sel.txt" ]; then
  if [ -n "$NAME" ]; then
    echo "ERROR: virtual cluster '$NAME'${NAMESPACE:+ in namespace $NAMESPACE} not found on the host" >&2
    exit 1
  fi
  echo "==> no virtual clusters found on the host"
fi

# names that exist in more than one namespace get the namespace in their context name
DUP_NAMES="$(awk '{print $2}' "$TMP/all.txt" | sort | uniq -d)"
ctx_name() {  # $1=namespace $2=name
  if printf '%s\n' "$DUP_NAMES" | grep -qx "$2"; then echo "k3k-${1#k3k-}-$2"; else echo "k3k-$2"; fi
}

echo "==> host $SERVER_HOST ($HOST_KCFG) -> $OUT_DIR"
mkdir -p "$OUT_DIR"
OK=0; FAILED=0; KEEP=()

# --- one cluster -------------------------------------------------------------------
generate() {  # $1=namespace $2=name $3=mode $4=phase
  local ns="$1" name="$2" mode="$3" phase="$4"
  local ctx out raw server ca cert key
  ctx="$(ctx_name "$ns" "$name")"
  out="$OUT_DIR/$ctx.yaml"
  KEEP+=("$out")
  printf '    %-28s %-7s %-8s -> %s\n' "$ns/$name" "$mode" "${phase:-?}" "$out"

  if [ "$phase" != "Ready" ]; then
    echo "      skipped: cluster is not Ready" >&2
    return 1
  fi

  raw="$TMP/$ns.$name.yaml"
  # k3kcli resolves --config-name relative to the cwd -> run it in the temp dir
  if ! ( cd "$TMP" && k3kcli kubeconfig generate \
          --kubeconfig "$HOST_KCFG" \
          --namespace "$ns" \
          --kubeconfig-server "$SERVER_HOST" \
          --config-name "$(basename "$raw")" \
          "$name" >/dev/null 2>"$TMP/k3kcli.log" ) || [ ! -s "$raw" ]; then
    echo "      k3kcli failed:" >&2; sed 's/^/        /' "$TMP/k3kcli.log" >&2
    return 1
  fi

  jp() { kubectl --kubeconfig "$raw" config view --raw -o jsonpath="$1"; }
  server="$(jp '{.clusters[0].cluster.server}')"
  ca="$(jp '{.clusters[0].cluster.certificate-authority-data}')"
  cert="$(jp '{.users[0].user.client-certificate-data}')"
  key="$(jp '{.users[0].user.client-key-data}')"
  if [ -z "$server" ] || [ -z "$ca" ] || [ -z "$cert" ] || [ -z "$key" ]; then
    echo "      unexpected kubeconfig layout from k3kcli" >&2
    return 1
  fi

  ( umask 077
    cat >"$TMP/final.yaml" <<EOF
$MARKER host=$SERVER_HOST cluster=$ns/$name
apiVersion: v1
kind: Config
clusters:
- name: $ctx
  cluster:
    server: $server
    certificate-authority-data: $ca
users:
- name: $ctx
  user:
    client-certificate-data: $cert
    client-key-data: $key
contexts:
- name: $ctx
  context:
    cluster: $ctx
    user: $ctx
current-context: $ctx
EOF
  )
  install -m 600 "$TMP/final.yaml" "$out"

  if kubectl --kubeconfig "$out" --request-timeout=8s get --raw /readyz >/dev/null 2>&1; then
    echo "      ok: $server reachable"
  else
    echo "      written, but $server not reachable from here (IP whitelisted? ./scripts/allow-my-ip.sh)" >&2
  fi
}

while read -r ns name mode phase; do
  [ -z "${name:-}" ] && continue
  if generate "$ns" "$name" "$mode" "${phase:-}"; then OK=$((OK + 1)); else FAILED=$((FAILED + 1)); fi
done <"$TMP/sel.txt"

# --- prune files of clusters that are gone -------------------------------------------
if [ "$PRUNE" -eq 1 ]; then
  if [ -n "$NAME" ] || [ -n "$NAMESPACE" ]; then
    echo "==> --prune ignored (only works when all clusters are processed)"
  else
    for f in "$OUT_DIR"/*.yaml; do
      [ -f "$f" ] || continue
      head -1 "$f" | grep -q "^$MARKER" || continue          # only files this script wrote
      keep=0
      for k in "${KEEP[@]:-}"; do [ "$f" = "$k" ] && keep=1; done
      if [ "$keep" -eq 0 ]; then rm -f "$f"; echo "==> pruned $f (cluster no longer exists)"; fi
    done
  fi
fi

echo "==> done: $OK written, $FAILED failed/skipped"
[ "$FAILED" -eq 0 ]