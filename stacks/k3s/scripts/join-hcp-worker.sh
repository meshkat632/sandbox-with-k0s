#!/usr/bin/env bash
# Join an existing EC2 instance (e.g. made by create-ec2.sh) as a worker to a K3k HCP
# virtual cluster, or remove it again.
#
#   1. host SG: allow the instance's public IP to the HCP NodePort
#   2. instance SG: allow traffic between workers (flannel, kubelet)
#   3. read join token + version from the host cluster
#   4. run the K3s agent install ON the instance via SSM Run Command
#   5. wait until the node is Ready in the HCP cluster
#
# Usage:
#   ./scripts/join-hcp-worker.sh INSTANCE_NAME [-c CLUSTER] [-N NAMESPACE] [-p NODEPORT] [--print] [--leave]
#
#   -c CLUSTER    HCP cluster name        (default hcp-1)
#   -N NAMESPACE  its host namespace      (default k3k-hcp)
#   -p NODEPORT   HCP apiserver NodePort  (default 30443)
#   --print       only print the join command (run it yourself in a session)
#   --leave       uninstall the agent, delete the node, remove the host SG rule
#
# Needs: aws CLI (AWS_PROFILE / AWS_REGION), python3, kubectl contexts k3k-host and k3k-<CLUSTER>.
# Note: SSM keeps the command (incl. the join token) in its Run Command history.
set -euo pipefail

INSTANCE=""
CLUSTER="hcp-1"
NAMESPACE="k3k-hcp"
NODEPORT=30443
PRINT=0
LEAVE=0
HOST_NAME_TAG="k3k-host"
HOST_SG_NAME="k3k-host-sg"
HOST_CONTEXT="${HOST_CONTEXT:-k3k-host}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--cluster)   CLUSTER="$2"; shift 2 ;;
    -N|--namespace) NAMESPACE="$2"; shift 2 ;;
    -p|--nodeport)  NODEPORT="$2"; shift 2 ;;
    --print)        PRINT=1; shift ;;
    --leave)        LEAVE=1; shift ;;
    -h|--help)      usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *)  INSTANCE="$1"; shift ;;
  esac
done
[ -n "$INSTANCE" ] || { echo "ERROR: INSTANCE_NAME is required" >&2; usage 1; }
for bin in aws kubectl python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found" >&2; exit 1; }
done

q() { aws "$@" --output text; }
none() { [ -z "$1" ] || [ "$1" = "None" ]; }
VC_CONTEXT="k3k-$CLUSTER"

# --- facts ---------------------------------------------------------------------------------
read -r WID WPUB WSG < <(q ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE" \
  Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].[InstanceId,PublicIpAddress,SecurityGroups[0].GroupId]')
none "${WID:-}" && { echo "ERROR: no running instance named $INSTANCE" >&2; exit 1; }
none "${WPUB:-}" && { echo "ERROR: $INSTANCE has no public IP" >&2; exit 1; }
HOST_PUB=$(q ec2 describe-instances --filters "Name=tag:Name,Values=$HOST_NAME_TAG" \
  Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].PublicIpAddress')
HOST_SG=$(q ec2 describe-security-groups --filters "Name=group-name,Values=$HOST_SG_NAME" \
  --query 'SecurityGroups[0].GroupId')
none "$HOST_PUB" && { echo "ERROR: host instance $HOST_NAME_TAG not running" >&2; exit 1; }
SERVER="https://$HOST_PUB:$NODEPORT"
echo "==> $INSTANCE ($WID, $WPUB) -> $NAMESPACE/$CLUSTER at $SERVER"

run_ssm() {  # $1 = shell script to run as root on the instance; prints its output
  local cid status
  cid=$(q ssm send-command --instance-ids "$WID" --document-name AWS-RunShellScript \
    --comment "k3k $CLUSTER: $INSTANCE" --timeout-seconds 600 \
    --parameters "$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$1")" \
    --query Command.CommandId)
  for _ in $(seq 1 120); do
    status=$(q ssm get-command-invocation --command-id "$cid" --instance-id "$WID" --query Status 2>/dev/null || echo Pending)
    case "$status" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 5
  done
  q ssm get-command-invocation --command-id "$cid" --instance-id "$WID" \
    --query '[StandardOutputContent,StandardErrorContent]' | sed 's/^/    | /'
  [ "$status" = "Success" ]
}

# --- leave ---------------------------------------------------------------------------------
if [ "$LEAVE" -eq 1 ]; then
  kubectl --context "$VC_CONTEXT" drain "$INSTANCE" --ignore-daemonsets --delete-emptydir-data --timeout=60s 2>/dev/null || true
  kubectl --context "$VC_CONTEXT" delete node "$INSTANCE" --ignore-not-found
  echo "==> uninstalling K3s agent on $INSTANCE"
  run_ssm '[ -x /usr/local/bin/k3s-agent-uninstall.sh ] && /usr/local/bin/k3s-agent-uninstall.sh || echo "no agent installed"' || true
  if aws ec2 revoke-security-group-ingress --group-id "$HOST_SG" --protocol tcp \
       --port "$NODEPORT" --cidr "$WPUB/32" >/dev/null 2>&1; then
    echo "==> removed host SG rule for $WPUB"
  fi
  exit 0
fi

# --- 1+2. firewall -----------------------------------------------------------------------
allow() {  # $1 = group, $2 = ip-permissions, $3 = message
  local err; err=$(mktemp)
  if aws ec2 authorize-security-group-ingress --group-id "$1" --ip-permissions "$2" >/dev/null 2>"$err"; then
    echo "==> $3"
  elif ! grep -q Duplicate "$err"; then
    cat "$err" >&2; rm -f "$err"; exit 1
  fi
  rm -f "$err"
}
allow "$HOST_SG" "IpProtocol=tcp,FromPort=$NODEPORT,ToPort=$NODEPORT,IpRanges=[{CidrIp=$WPUB/32,Description=$INSTANCE}]" \
  "host SG: allowed $WPUB -> $NODEPORT"
allow "$WSG" "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$WSG}]" "worker SG: allowed worker-to-worker traffic"

# --- 3. join values -----------------------------------------------------------------------
kh() { kubectl --context "$HOST_CONTEXT" "$@"; }
TOKEN=""
for s in "k3k-$CLUSTER-token" "$CLUSTER-token"; do
  TOKEN=$(kh -n "$NAMESPACE" get secret "$s" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
  [ -n "$TOKEN" ] && break
done
[ -n "$TOKEN" ] || { echo "ERROR: join token secret not found in $NAMESPACE" >&2; exit 1; }
VER=$(kh -n "$NAMESPACE" get clusters.k3k.io "$CLUSTER" -o jsonpath='{.spec.version}')
[ -n "$VER" ] || VER=$(kh get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
VER="${VER/-k3s/+k3s}"

JOIN="curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$VER' K3S_URL='$SERVER' K3S_TOKEN='$TOKEN' sh -s - agent --node-name $INSTANCE --node-external-ip $WPUB"

if [ "$PRINT" -eq 1 ]; then
  echo
  echo "Run as root on $INSTANCE (aws ssm start-session --target $WID). Contains the join token:"
  echo
  echo "sudo bash -c \"$JOIN\""
  exit 0
fi

# --- 4. install the agent via SSM ----------------------------------------------------------
echo "==> checking that $INSTANCE is managed by SSM"
for i in $(seq 1 24); do
  [ "$(q ssm describe-instance-information --filters "Key=InstanceIds,Values=$WID" \
        --query 'InstanceInformationList[0].PingStatus')" = "Online" ] && break
  [ "$i" -eq 24 ] && { echo "ERROR: $WID not online in SSM (role ec2-ssm attached? wait and retry)" >&2; exit 1; }
  sleep 5
done

echo "==> installing K3s agent $VER on $INSTANCE (via SSM)"
run_ssm "set -e
code=\$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 $SERVER/readyz || true)
echo \"apiserver $SERVER answered HTTP \$code\"
case \"\$code\" in 200|401|403) ;; *) echo 'cannot reach the HCP apiserver' >&2; exit 1 ;; esac
$JOIN
systemctl is-active k3s-agent" || { echo "ERROR: join failed (see output above)" >&2; exit 1; }

# --- 5. wait for Ready ------------------------------------------------------------------------
echo "==> waiting for node $INSTANCE to register and become Ready in $VC_CONTEXT"
for _ in $(seq 1 24); do   # the node object appears a few seconds after the agent starts
  kubectl --context "$VC_CONTEXT" get node "$INSTANCE" >/dev/null 2>&1 && break
  sleep 5
done
if kubectl --context "$VC_CONTEXT" wait --for=condition=Ready "node/$INSTANCE" --timeout=180s >/dev/null; then
  kubectl --context "$VC_CONTEXT" get nodes -o wide
else
  echo "WARN: not Ready yet; check: aws ssm start-session --target $WID ; journalctl -u k3s-agent" >&2
  exit 1
fi