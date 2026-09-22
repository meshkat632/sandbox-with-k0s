#!/usr/bin/env bash
# Fetches the k0s admin kubeconfig from the controller node over SSM
# (no SSH key needed) and rewrites the API server address from
# localhost to the controller's public IP so it works from your machine.
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [-i INSTANCE_ID] [-o OUTPUT_PATH] [-k]

  -i INSTANCE_ID  Controller instance ID (default: first id in
                  'terraform output -json k0s_node_ids')
  -o OUTPUT_PATH  Where to write the kubeconfig (default: ~/.kube/config-k0stool)
  -k              Skip TLS verification (insecure-skip-tls-verify: true).
                  Needed for the public IP: k0s's API server cert only
                  has SANs for the node's own private IP/localhost, not
                  its public IP, so verification fails against it even
                  though the connection itself is fine.
  -h              Show this help
EOF
}

INSTANCE_ID=""
OUTPUT_PATH="$HOME/.kube/config-k0stool"
INSECURE=""

while getopts "i:o:kh" opt; do
  case "$opt" in
    i) INSTANCE_ID="$OPTARG" ;;
    o) OUTPUT_PATH="$OPTARG" ;;
    k) INSECURE="1" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID=$(cd "$INFRA_DIR" && terraform output -json k0s_node_ids | jq -r '.[0]')
fi

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
  echo "error: could not determine controller instance ID (pass -i explicitly)" >&2
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
