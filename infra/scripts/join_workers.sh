#!/usr/bin/env bash
# Joins one or more freshly-launched instances to an existing k0s cluster
# as workers, over SSM (no SSH key needed). Use this after raising
# instance_count and applying: pass the new instances' IDs here.
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [-c CONTROLLER_ID] WORKER_INSTANCE_ID [WORKER_INSTANCE_ID ...]

  -c CONTROLLER_ID  Controller instance ID (default: first id in
                     'terraform output -json k0s_node_ids')
  -h                Show this help

Example — raise instance_count, apply, then join whatever's new:
  terraform apply -var 'instance_count=3'
  terraform output -json k0s_node_ids | jq -r '.[]'   # find the new ids
  scripts/join_workers.sh i-newworker1 i-newworker2
EOF
}

CONTROLLER_ID=""

while getopts "c:h" opt; do
  case "$opt" in
    c) CONTROLLER_ID="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [ "$#" -eq 0 ]; then
  echo "error: pass at least one worker instance ID to join" >&2
  usage >&2
  exit 1
fi
WORKER_IDS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "$CONTROLLER_ID" ]; then
  CONTROLLER_ID=$(cd "$INFRA_DIR" && terraform output -json k0s_node_ids | jq -r '.[0]')
fi

if [ -z "$CONTROLLER_ID" ] || [ "$CONTROLLER_ID" = "null" ]; then
  echo "error: could not determine controller instance ID (pass -c explicitly)" >&2
  exit 1
fi

wait_for_command() {
  local cmd_id="$1" instance_id="$2"
  for _ in $(seq 1 60); do
    local status
    status=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$instance_id" \
      --query "Status" --output text 2>/dev/null || echo "Pending")
    case "$status" in
      Success) return 0 ;;
      InProgress | Pending | Delayed) sleep 5 ;;
      *)
        echo "error: command $cmd_id on $instance_id finished with status $status" >&2
        aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$instance_id" \
          --query "StandardErrorContent" --output text >&2
        return 1
        ;;
    esac
  done
  echo "error: command $cmd_id on $instance_id timed out" >&2
  return 1
}

echo "controller: $CONTROLLER_ID" >&2

CONTROLLER_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$CONTROLLER_ID" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)

if [ -z "$CONTROLLER_PRIVATE_IP" ] || [ "$CONTROLLER_PRIVATE_IP" = "None" ]; then
  echo "error: could not determine private IP for controller $CONTROLLER_ID" >&2
  exit 1
fi

echo "generating worker join token on $CONTROLLER_ID..." >&2
TOKEN_CMD_ID=$(aws ssm send-command \
  --instance-ids "$CONTROLLER_ID" \
  --document-name AWS-RunShellScript \
  --comment "generate k0s worker token" \
  --parameters '{"commands":["sudo k0s token create --role worker"]}' \
  --query "Command.CommandId" --output text)

wait_for_command "$TOKEN_CMD_ID" "$CONTROLLER_ID"

TOKEN=$(aws ssm get-command-invocation --command-id "$TOKEN_CMD_ID" --instance-id "$CONTROLLER_ID" \
  --query "StandardOutputContent" --output text | tr -d '\n')

if [ -z "$TOKEN" ]; then
  echo "error: got an empty join token — is $CONTROLLER_ID actually the controller?" >&2
  exit 1
fi

SCRIPT_B64=$(base64 -w0 "$SCRIPT_DIR/install_k0s.py")

FAILED=0
for WORKER_ID in "${WORKER_IDS[@]}"; do
  echo "joining $WORKER_ID..." >&2
  PARAMS=$(python3 - "$SCRIPT_B64" "$TOKEN" "$CONTROLLER_PRIVATE_IP" <<'PYEOF'
import json, sys
script_b64, token, controller_ip = sys.argv[1], sys.argv[2], sys.argv[3]
commands = [
    f"echo {script_b64} | base64 -d > /tmp/install_k0s.py",
    f"sudo python3 /tmp/install_k0s.py --role worker --controller-ip {controller_ip} --token '{token}'",
]
print(json.dumps({"commands": commands}))
PYEOF
)
  CMD_ID=$(aws ssm send-command \
    --instance-ids "$WORKER_ID" \
    --document-name AWS-RunShellScript \
    --comment "k0s worker join" \
    --timeout-seconds 600 \
    --parameters "$PARAMS" \
    --query "Command.CommandId" --output text)

  if wait_for_command "$CMD_ID" "$WORKER_ID"; then
    echo "$WORKER_ID joined." >&2
  else
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo "one or more workers failed to join — see errors above" >&2
  exit 1
fi

echo "" >&2
echo "done. verify with: kubectl get nodes" >&2
