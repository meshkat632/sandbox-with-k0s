#!/usr/bin/env bash
# Fetch the K3s kubeconfig from server 0 over SSM Session Manager and write it as its
# own file, one cluster per file: ~/.kube/configs/<name>.yaml (never merged into another file).
#
# The kubeconfig points at the public API load balancer "<NAME>-api", which only accepts
# the CIDRs in Terraform's allowed_cidrs. Only the fetch itself goes over SSM.
#
# Usage:
#   ./scripts/get-kubeconfig.sh [-r REGION] [-n NAME] [-i INSTANCE_ID] [-d DIR] [--no-switch]
#
#   -n NAME        Terraform var.name; server 0 is the instance tagged "<NAME>-server-0" (default k3s-prod)
#   -i INSTANCE_ID read the file from this instance instead of looking server 0 up by tag
#   -d DIR         folder for the file (default ~/.kube/configs)
#   --no-switch    don't change the current context
#
# Defaults can also be set via env: AWS_REGION, KUBECONFIG_DIR.
# Uses your normal AWS credentials (e.g. export AWS_PROFILE=...).
set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
NAME="k3s-prod"
INSTANCE_ID=""
OUT_DIR="${KUBECONFIG_DIR:-$HOME/.kube/configs}"
SWITCH=1

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--region)       REGION="$2"; shift 2 ;;
    -n|--name)         NAME="$2"; shift 2 ;;
    -i|--instance-id)  INSTANCE_ID="$2"; shift 2 ;;
    -d|--dir)          OUT_DIR="$2"; shift 2 ;;
    --no-switch)       SWITCH=0; shift ;;
    -h|--help)         usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

for bin in aws kubectl session-manager-plugin base64; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH" >&2; exit 1; }
done

if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${NAME}-server-0" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    echo "ERROR: no running instance tagged '${NAME}-server-0' in $REGION" >&2
    exit 1
  fi
fi

API_HOST="$(aws elbv2 describe-load-balancers --region "$REGION" --names "${NAME}-api" \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)"
if [ -z "$API_HOST" ] || [ "$API_HOST" = "None" ]; then
  echo "ERROR: load balancer '${NAME}-api' not found in $REGION (terraform apply done?)" >&2
  exit 1
fi

TMPDIR_K="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_K"' EXIT
NEW="$TMPDIR_K/new.yaml"

# --- 1. Read the kubeconfig through a Session Manager session --------------------
# A session (not Run Command) so the admin credentials don't land in the SSM command
# history. base64 between markers keeps the session banner and CRLFs out of the file.
echo "==> Reading /etc/rancher/k3s/k3s.yaml from $INSTANCE_ID ($REGION)"
# The command is exec'd without a shell, hence bash -c. stdin is held open because the
# session plugin gives up with "EOF" when it is closed (e.g. when run from a script).
REMOTE="sudo bash -c 'echo KUBECONFIG_BEGIN; base64 -w 76 /etc/rancher/k3s/k3s.yaml; echo KUBECONFIG_END'"
if ! aws ssm start-session --region "$REGION" --target "$INSTANCE_ID" \
     --document-name AWS-StartNonInteractiveCommand \
     --parameters "{\"command\":[\"$REMOTE\"]}" \
     >"$TMPDIR_K/session" 2>"$TMPDIR_K/err" < <(exec sleep 120); then
  echo "ERROR: SSM session failed (is the instance registered with SSM?):" >&2
  cat "$TMPDIR_K/err" >&2
  exit 1
fi

tr -d '\r' <"$TMPDIR_K/session" \
  | sed -n '/^KUBECONFIG_BEGIN$/,/^KUBECONFIG_END$/p' | sed '1d;$d' \
  | base64 -d >"$NEW" 2>/dev/null || true
if ! grep -q '^apiVersion:' "$NEW"; then
  echo "ERROR: no kubeconfig came back from $INSTANCE_ID (K3s still starting?)" >&2
  exit 1
fi
chmod 600 "$NEW"

# --- 2. Name everything after the cluster, point it at the load balancer ---------
# K3s calls its cluster, user and context all "default".
sed -i -E "s/^(\s*(- )?(name|cluster|user|current-context): )default$/\1${NAME}/" "$NEW"
# The load balancer's DNS name is not in the K3s serving certificate, so verify the
# certificate against "kubernetes", which is. The cluster CA is still checked.
KUBECONFIG="$NEW" kubectl config set-cluster "$NAME" \
  --server="https://${API_HOST}:6443" --tls-server-name=kubernetes >/dev/null

CONTEXT="$(KUBECONFIG="$NEW" kubectl config current-context)"
SERVER="$(KUBECONFIG="$NEW" kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"
echo "    context: $CONTEXT  server: $SERVER"

# --- 3. Write the per-cluster file ----------------------------------------------
mkdir -p "$OUT_DIR"
TARGET="$OUT_DIR/$CONTEXT.yaml"
install -m 600 "$NEW" "$TARGET"
echo "==> Wrote $TARGET"

# --- 4. Is the file visible to kubectl/kubectx in your shell? ------------------
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

# --- 5. Quick connectivity check -----------------------------------------------
echo "==> kubectl get nodes"
if ! kubectl --kubeconfig "$TARGET" --context "$CONTEXT" --request-timeout=10s get nodes -o wide; then
  echo "WARN: API not reachable at ${API_HOST}:6443. Is your current public IP in" >&2
  echo "      allowed_cidrs (terraform.tfvars)? A new load balancer also needs a few minutes." >&2
  exit 2
fi
