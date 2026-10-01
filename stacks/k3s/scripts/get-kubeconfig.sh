#!/usr/bin/env bash
# Fetch the K3s kubeconfig from AWS Secrets Manager and merge it into your
# local kubeconfig (~/.kube/config), then switch to its context.
#
# Usage:
#   ./scripts/get-kubeconfig.sh [-r REGION] [-s SECRET_ID] [-k KUBECONFIG_FILE] [-w WAIT_SECONDS] [--no-switch]
#
# Defaults can also be set via env: AWS_REGION, SECRET_ID, KUBECONFIG_FILE.
# Uses your normal AWS credentials (e.g. export AWS_PROFILE=...).
set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
SECRET_ID="${SECRET_ID:-k3k-host/kubeconfig}"
TARGET="${KUBECONFIG_FILE:-$HOME/.kube/config}"
WAIT_SECONDS=300
SWITCH=1

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--region)     REGION="$2"; shift 2 ;;
    -s|--secret-id)  SECRET_ID="$2"; shift 2 ;;
    -k|--kubeconfig) TARGET="$2"; shift 2 ;;
    -w|--wait)       WAIT_SECONDS="$2"; shift 2 ;;
    --no-switch)     SWITCH=0; shift ;;
    -h|--help)       usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

for bin in aws kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done

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

# --- 2. Merge into the target kubeconfig (new entries win over old ones) ---
mkdir -p "$(dirname "$TARGET")"
if [ -s "$TARGET" ]; then
  BACKUP="$TARGET.bak.$(date +%Y%m%d%H%M%S)"
  cp "$TARGET" "$BACKUP"
  echo "==> Backed up $TARGET -> $BACKUP"

  # Drop stale entries with the same names, then merge.
  OLD="$TMPDIR_K/old.yaml"
  cp "$TARGET" "$OLD"
  KUBECONFIG="$OLD" kubectl config delete-context "$CONTEXT" >/dev/null 2>&1 || true
  KUBECONFIG="$OLD" kubectl config delete-cluster "$CONTEXT" >/dev/null 2>&1 || true
  KUBECONFIG="$OLD" kubectl config delete-user    "$CONTEXT" >/dev/null 2>&1 || true

  # The first file supplies current-context, so put the old file first unless switching.
  if [ "$SWITCH" -eq 1 ]; then ORDER="$NEW:$OLD"; else ORDER="$OLD:$NEW"; fi
  KUBECONFIG="$ORDER" kubectl config view --flatten >"$TMPDIR_K/merged.yaml"
  install -m 600 "$TMPDIR_K/merged.yaml" "$TARGET"
else
  install -m 600 "$NEW" "$TARGET"
fi
echo "==> Merged context '$CONTEXT' into $TARGET"

if [ "$SWITCH" -eq 1 ]; then
  kubectl --kubeconfig "$TARGET" config use-context "$CONTEXT" >/dev/null
  echo "==> Current context is now '$CONTEXT'"
fi

# --- 3. Quick connectivity check ---
echo "==> kubectl get nodes"
if ! kubectl --kubeconfig "$TARGET" --context "$CONTEXT" --request-timeout=10s get nodes -o wide; then
  echo "WARN: API not reachable from here. Check that your public IP is in allowed_cidrs" >&2
  echo "      (curl -s https://checkip.amazonaws.com) and that the instance is running." >&2
  exit 2
fi