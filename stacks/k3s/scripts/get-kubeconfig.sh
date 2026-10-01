#!/usr/bin/env bash
# Fetch the K3s kubeconfig from AWS Secrets Manager and write it as its own file,
# one cluster per file: ~/.kube/configs/<context>.yaml (never merged into another file).
# kubectx (KUBECONFIG built from that folder) and Lens (folder sync) both pick it up.
#
# Usage:
#   ./scripts/get-kubeconfig.sh [-r REGION] [-s SECRET_ID] [-d DIR] [-w WAIT_SECONDS] [--no-switch] [--allow-my-ip]
#
#   -d DIR         folder for the file (default ~/.kube/configs)
#   --no-switch    don't change the current context
#   --allow-my-ip  first whitelist your current public IP (runs allow-my-ip.sh)
#
# Defaults can also be set via env: AWS_REGION, SECRET_ID, KUBECONFIG_DIR.
# Uses your normal AWS credentials (e.g. export AWS_PROFILE=...).
set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
SECRET_ID="${SECRET_ID:-k3k-host/kubeconfig}"
OUT_DIR="${KUBECONFIG_DIR:-$HOME/.kube/configs}"
WAIT_SECONDS=300
SWITCH=1
ALLOW_MY_IP=0

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--region)     REGION="$2"; shift 2 ;;
    -s|--secret-id)  SECRET_ID="$2"; shift 2 ;;
    -d|--dir)        OUT_DIR="$2"; shift 2 ;;
    -w|--wait)       WAIT_SECONDS="$2"; shift 2 ;;
    --no-switch)     SWITCH=0; shift ;;
    --allow-my-ip)   ALLOW_MY_IP=1; shift ;;
    -h|--help)       usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

for bin in aws kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done

if [ "$ALLOW_MY_IP" -eq 1 ]; then
  "$(dirname "$0")/allow-my-ip.sh" -r "$REGION"
fi

TMPDIR_K="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_K"' EXIT
NEW="$TMPDIR_K/new.yaml"

# --- 1. Fetch the secret (wait while the instance is still bootstrapping) ---
echo "==> Fetching '$SECRET_ID' from Secrets Manager ($REGION)"
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
  if aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ID" \
       --query SecretString --output text >"$NEW" 2>"$TMPDIR_K/err" && [ -s "$NEW" ]; then
    break
  fi
  if grep -q "AWSCURRENT" "$TMPDIR_K/err" && [ "$(date +%s)" -lt "$deadline" ]; then
    echo "    kubeconfig not published yet (K3s still starting), retrying in 15s..."
    sleep 15
    continue
  fi
  echo "ERROR: could not read secret:" >&2
  cat "$TMPDIR_K/err" >&2
  exit 1
done
chmod 600 "$NEW"

CONTEXT="$(KUBECONFIG="$NEW" kubectl config current-context)"
SERVER="$(KUBECONFIG="$NEW" kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"
echo "    context: $CONTEXT  server: $SERVER"

# --- 2. Write the per-cluster file ----------------------------------------------
mkdir -p "$OUT_DIR"
TARGET="$OUT_DIR/$CONTEXT.yaml"
install -m 600 "$NEW" "$TARGET"
echo "==> Wrote $TARGET"

# --- 3. Is the file visible to kubectl/kubectx in your shell? ------------------
ACTIVE="${KUBECONFIG:-$HOME/.kube/config}"
IN_LIST=0
IFS=':' read -r -a ACTIVE_FILES <<<"$ACTIVE"
for f in "${ACTIVE_FILES[@]}"; do
  [ "$f" -ef "$TARGET" ] 2>/dev/null && IN_LIST=1
done
if [ "$IN_LIST" -eq 0 ]; then
  ACTIVE="$ACTIVE:$TARGET"
fi

if [ "$SWITCH" -eq 1 ]; then
  KUBECONFIG="$ACTIVE" kubectl config use-context "$CONTEXT" >/dev/null
  echo "==> Current context is now '$CONTEXT'"
fi

if [ "$IN_LIST" -eq 0 ]; then
  echo
  echo "NOTE: $TARGET is new, so plain kubectl in this shell doesn't see '$CONTEXT' yet."
  echo "      'kx' / 'kn' pick it up automatically (they re-scan $OUT_DIR)."
  echo "      For plain kubectl run: kubeconfig_refresh   (or open a new shell)"
  echo
fi

# --- 4. Quick connectivity check -----------------------------------------------
echo "==> kubectl get nodes"
if ! kubectl --kubeconfig "$TARGET" --context "$CONTEXT" --request-timeout=10s get nodes -o wide; then
  echo "WARN: API not reachable from here. Your IP may have changed: run" >&2
  echo "      ./scripts/allow-my-ip.sh (or re-run with --allow-my-ip), and check the instance is running." >&2
  exit 2
fi