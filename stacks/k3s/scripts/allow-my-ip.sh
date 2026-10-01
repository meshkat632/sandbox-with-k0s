#!/usr/bin/env bash
# Whitelist your CURRENT public IP on the K3s security group (API 6443 + NodePorts)
# and remove the IP this script added for you last time.
#
# Usage:
#   ./scripts/allow-my-ip.sh [-r REGION] [-n NAME | -g SG_ID] [-l LABEL] [--api-only] [--remove]
#
#   -n NAME     Terraform var.name; the security group is "<NAME>-sg" (default k3k-host)
#   -l LABEL    who owns the rule, so several people can each keep one IP (default: $USER)
#   --api-only  only open 6443, not the NodePort range
#   --remove    just delete your dynamic rules
#
# Rules are tagged dynamic-ip-owner=<LABEL>. They are separate from the rules Terraform
# manages, so `terraform apply` neither shows nor removes them. If Terraform already
# allows your IP (allow_runner_ip = true), nothing is added.
set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
NAME="k3k-host"
SG_ID=""
LABEL="${USER:-me}"
API_ONLY=0
REMOVE=0

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--region)   REGION="$2"; shift 2 ;;
    -n|--name)     NAME="$2"; shift 2 ;;
    -g|--sg-id)    SG_ID="$2"; shift 2 ;;
    -l|--label)    LABEL="$2"; shift 2 ;;
    --api-only)    API_ONLY=1; shift ;;
    --remove)      REMOVE=1; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

LABEL="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '-')"
TAG_KEY="dynamic-ip-owner"

if [ -z "$SG_ID" ]; then
  SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=${NAME}-sg" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    echo "ERROR: security group '${NAME}-sg' not found in $REGION" >&2
    exit 1
  fi
fi

# Existing dynamic rules owned by LABEL: "<rule-id> <cidr> <from-port>" per line
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
EXISTING="$(aws ec2 describe-security-group-rules --region "$REGION" \
  --filters "Name=group-id,Values=$SG_ID" "Name=tag:$TAG_KEY,Values=$LABEL" \
  --query 'SecurityGroupRules[?IsEgress==`false`].[SecurityGroupRuleId,CidrIpv4,FromPort]' \
  --output text)"

if [ "$REMOVE" -eq 1 ]; then
  MY_CIDR="none"
else
  MY_IP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
  if ! printf '%s' "$MY_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    echo "ERROR: could not determine public IPv4 (got '$MY_IP')" >&2
    exit 1
  fi
  MY_CIDR="$MY_IP/32"
fi

echo "==> $SG_ID ($REGION), owner '$LABEL', current IP: $MY_CIDR"

# Ports already open to this IP by ANY rule (e.g. Terraform's allow_runner_ip rules)
OTHER_PORTS=""
if [ "$REMOVE" -eq 0 ]; then
  OTHER_PORTS="$(aws ec2 describe-security-group-rules --region "$REGION" \
    --filters "Name=group-id,Values=$SG_ID" \
    --query "SecurityGroupRules[?IsEgress==\`false\` && CidrIpv4=='$MY_CIDR'].FromPort" \
    --output text)"
fi

STALE=()
HAVE_API=0
HAVE_NODEPORT=0
while read -r rule_id cidr from_port; do
  [ -z "${rule_id:-}" ] && continue
  if [ "$cidr" = "$MY_CIDR" ]; then
    case "$from_port" in
      6443)  HAVE_API=1 ;;
      30000) if [ "$API_ONLY" -eq 1 ]; then STALE+=("$rule_id"); else HAVE_NODEPORT=1; fi ;;
      *)     STALE+=("$rule_id") ;;
    esac
  else
    STALE+=("$rule_id")
  fi
done <<<"$EXISTING"

for p in $OTHER_PORTS; do
  [ "$p" = "6443" ] && HAVE_API=1
  [ "$p" = "30000" ] && HAVE_NODEPORT=1
done

# Add the new IP first, then remove old ones, so there is no gap.
PERMS=()
DESC="k3k-dynamic-ip-$LABEL"
if [ "$REMOVE" -eq 0 ] && [ "$HAVE_API" -eq 0 ]; then
  PERMS+=("IpProtocol=tcp,FromPort=6443,ToPort=6443,IpRanges=[{CidrIp=$MY_CIDR,Description=$DESC}]")
fi
if [ "$REMOVE" -eq 0 ] && [ "$API_ONLY" -eq 0 ] && [ "$HAVE_NODEPORT" -eq 0 ]; then
  PERMS+=("IpProtocol=tcp,FromPort=30000,ToPort=32767,IpRanges=[{CidrIp=$MY_CIDR,Description=$DESC}]")
fi

if [ "${#PERMS[@]}" -gt 0 ]; then
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --ip-permissions "${PERMS[@]}" \
    --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=$TAG_KEY,Value=$LABEL}]" \
    >/dev/null
  echo "    added $MY_CIDR (${#PERMS[@]} rule(s))"
elif [ "$REMOVE" -eq 0 ]; then
  echo "    $MY_CIDR already allowed"
fi

if [ "${#STALE[@]}" -gt 0 ]; then
  aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --security-group-rule-ids "${STALE[@]}" >/dev/null
  echo "    removed ${#STALE[@]} old rule(s)"
fi
echo "==> done"