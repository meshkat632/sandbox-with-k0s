#!/usr/bin/env bash
# Block until the K3s node is usable:
#   1. its kubeconfig for the CURRENT public IP is published in Secrets Manager
#   2. the API server answers from this machine (security group + TLS listener OK)
#   3. all nodes are Ready (only if kubectl is installed)
#
# Called by Terraform (terraform_data.wait_for_k3s) but can also be run by hand:
#   PUBLIC_IP=3.76.190.187 ./scripts/wait-for-k3s.sh
#
# Env: PUBLIC_IP (required), REGION, SECRET_ID, TIMEOUT (seconds), CHECK_API (true/false)
set -euo pipefail

PUBLIC_IP="${PUBLIC_IP:?PUBLIC_IP is required}"
REGION="${REGION:-${AWS_REGION:-eu-central-1}}"
SECRET_ID="${SECRET_ID:-k3k-host/kubeconfig}"
TIMEOUT="${TIMEOUT:-600}"
CHECK_API="${CHECK_API:-true}"
SERVER="https://$PUBLIC_IP:6443"

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found (set wait_for_ready = false to skip)" >&2; exit 1; }

START=$(date +%s)
DEADLINE=$(( START + TIMEOUT ))
elapsed() { echo "$(( $(date +%s) - START ))s"; }
timed_out() { [ "$(date +%s)" -ge "$DEADLINE" ]; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
KCFG="$TMP/kubeconfig.yaml"

# --- 1. kubeconfig for this IP published ------------------------------------
echo "==> [1/3] waiting for kubeconfig for $SERVER in '$SECRET_ID'"
while :; do
  if aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ID" \
       --query SecretString --output text >"$KCFG" 2>"$TMP/err"; then
    if grep -q "server: $SERVER\$" "$KCFG"; then
      echo "    published ($(elapsed))"
      break
    fi
    msg="secret still holds an older kubeconfig"
  elif grep -q "AWSCURRENT" "$TMP/err"; then
    msg="not published yet"
  else
    echo "ERROR: reading secret failed:" >&2
    cat "$TMP/err" >&2
    exit 1
  fi
  if timed_out; then
    echo "ERROR: timed out after $(elapsed): $msg." >&2
    echo "       Check the node: /var/log/k3s-bootstrap.log, journalctl -u k3s-kubeconfig-publish" >&2
    exit 1
  fi
  echo "    $msg, retrying... ($(elapsed))"
  sleep 10
done
chmod 600 "$KCFG"

if [ "$CHECK_API" != "true" ]; then
  echo "==> API checks skipped (CHECK_API=$CHECK_API)"
  exit 0
fi

# --- 2. API server reachable from here --------------------------------------
echo "==> [2/3] waiting for $SERVER/readyz to answer from this machine"
while :; do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$SERVER/readyz" || true)"
  case "$code" in
    200|401|403) echo "    API answered HTTP $code ($(elapsed))"; break ;;
  esac
  if timed_out; then
    echo "ERROR: timed out after $(elapsed): API not reachable (HTTP '$code')." >&2
    echo "       Is this machine's IP whitelisted? curl -s https://checkip.amazonaws.com" >&2
    exit 1
  fi
  echo "    no answer yet (HTTP '$code'), retrying... ($(elapsed))"
  sleep 5
done

# --- 3. nodes Ready ----------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  echo "==> [3/3] kubectl not installed, skipping node readiness check"
  exit 0
fi
echo "==> [3/3] waiting for nodes to be Ready"
while :; do
  if out="$(kubectl --kubeconfig "$KCFG" --request-timeout=5s get nodes --no-headers 2>/dev/null)" \
     && [ -n "$out" ] && ! printf '%s\n' "$out" | awk '{print $2}' | grep -qv '^Ready'; then
    printf '%s\n' "$out" | sed 's/^/    /'
    echo "==> K3s is ready ($(elapsed))"
    exit 0
  fi
  if timed_out; then
    echo "ERROR: timed out after $(elapsed) waiting for nodes to be Ready." >&2
    exit 1
  fi
  sleep 5
done