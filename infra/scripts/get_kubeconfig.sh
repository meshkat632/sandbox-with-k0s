#!/usr/bin/env bash
# Fetches the k0s admin kubeconfig from the controller node over SSM
# (no SSH key needed) and rewrites the API server address from
# localhost to the controller's public IP so it works from your machine.
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [-i INSTANCE_ID] [-t TAG_KEY=TAG_VALUE] [-o OUTPUT_PATH] [-k] [-S]

  -i INSTANCE_ID  Controller instance ID. If omitted, the script looks
                  up a running instance by tag (see -t).
  -t TAG_KEY=VAL  Tag used to find the controller instance when
                  -i is not given (default: k0s-role=controller).
                  Only the first matching running instance is used.
  -o OUTPUT_PATH  Where to write the kubeconfig (default: ~/.kube/config-k0stool)
  -k              Skip TLS verification (insecure-skip-tls-verify: true).
                  Needed for the public IP: k0s's API server cert only
                  has SANs for the node's own private IP/localhost, not
                  its public IP, so verification fails against it even
                  though the connection itself is fine.
  -S              Don't push the fetched kubeconfig to the
                  kubeconfig_secret_name Secrets Manager secret (pushed
                  by default, so anyone with secretsmanager:GetSecretValue
                  on it can fetch this same kubeconfig).
  -h              Show this help
EOF
}

INSTANCE_ID=""
TAG="k0s-role=controller"
OUTPUT_PATH="$HOME/.kube/config-k0stool"
INSECURE=""
SKIP_SECRET=""

while getopts "i:t:o:kSh" opt; do
  case "$opt" in
    i) INSTANCE_ID="$OPTARG" ;;
    t) TAG="$OPTARG" ;;
    o) OUTPUT_PATH="$OPTARG" ;;
    k) INSECURE="1" ;;
    S) SKIP_SECRET="1" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [ -z "$INSTANCE_ID" ]; then
  TAG_KEY="${TAG%%=*}"
  TAG_VAL="${TAG#*=}"
  if [ -z "$TAG_KEY" ] || [ -z "$TAG_VAL" ] || [ "$TAG_KEY" = "$TAG" ]; then
    echo "error: -t must be in the form TAG_KEY=TAG_VALUE (got: $TAG)" >&2
    exit 1
  fi
  echo "looking up controller instance by tag $TAG_KEY=$TAG_VAL..." >&2
  INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VAL}" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId | [0]" --output text)
fi

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "error: could not determine controller instance ID (pass -i explicitly, or -t TAG_KEY=VALUE to match it)" >&2
  exit 1
fi

echo "fetching kubeconfig from controller $INSTANCE_ID via SSM..." >&2

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "fetch k0s admin kubeconfig" \
  --parameters '{"commands":["sudo k0s kubeconfig admin"]}' \
  --query "Command.CommandId" --output text)

for _ in $(seq 1 30); do
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query "Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Success) break ;;
    InProgress | Pending | Delayed) sleep 3 ;;
    *)
      echo "error: SSM command finished with status $STATUS" >&2
      aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
        --query "StandardErrorContent" --output text >&2
      exit 1
      ;;
  esac
done

KUBECONFIG_CONTENT=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardOutputContent" --output text)

if [ -z "$KUBECONFIG_CONTENT" ]; then
  echo "error: empty kubeconfig returned — is k0s installed as controller on $INSTANCE_ID?" >&2
  exit 1
fi

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
  echo "error: could not determine public IP for $INSTANCE_ID" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
umask 077
# k0s embeds the node's own address (its private IP, or "localhost" on
# some builds) as the API server host — replace whatever that is with
# the public IP so the file works from outside the VPC.
REWRITTEN=$(printf '%s\n' "$KUBECONFIG_CONTENT" | sed -E "s#https://[^:]+:6443#https://${PUBLIC_IP}:6443#")

if [ -n "$INSECURE" ]; then
  # drop the CA cert (verified against the private-IP SANs) and skip
  # verification instead, since the cert has no SAN for the public IP.
  REWRITTEN=$(printf '%s\n' "$REWRITTEN" | sed -E "s#^(\s*)certificate-authority-data:.*#\1insecure-skip-tls-verify: true#")
fi

printf '%s\n' "$REWRITTEN" > "$OUTPUT_PATH"

echo "kubeconfig written to $OUTPUT_PATH (server: $(grep -oE 'https://[^ ]+:6443' "$OUTPUT_PATH" | head -1))" >&2
if [ -n "$INSECURE" ]; then
  echo "TLS verification disabled (-k) — cert has no SAN for the public IP." >&2
fi
echo "" >&2
echo "  export KUBECONFIG=$OUTPUT_PATH" >&2
echo "" >&2
if [ -z "$INSECURE" ]; then
  echo "note: kubectl will fail cert verification against the public IP (k0s's cert has no SAN for it) — pass -k, or tunnel via SSM (see README)." >&2
fi

if [ -z "$SKIP_SECRET" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  SECRET_NAME=$(cd "$INFRA_DIR" && terraform output -raw kubeconfig_secret_name 2>/dev/null || true)

  if [ -z "$SECRET_NAME" ]; then
    echo "" >&2
    echo "warning: could not read kubeconfig_secret_name from terraform output (state not applied here?) — skipping Secrets Manager push. Pass -S to silence this." >&2
  else
    echo "" >&2
    echo "pushing kubeconfig to Secrets Manager secret $SECRET_NAME..." >&2
    if aws secretsmanager put-secret-value --secret-id "$SECRET_NAME" --secret-string "$REWRITTEN" >/dev/null; then
      echo "pushed. anyone with secretsmanager:GetSecretValue on it can fetch this same kubeconfig:" >&2
      echo "  aws secretsmanager get-secret-value --secret-id $SECRET_NAME --query SecretString --output text > ~/.kube/config-k0stool" >&2
    else
      echo "warning: failed to push kubeconfig to Secrets Manager secret $SECRET_NAME" >&2
    fi
  fi
fi