#!/usr/bin/env bash
# Create (or delete) a plain Ubuntu 24.04 EC2 instance in the DEFAULT VPC / default
# subnet with a public IP. Shell access via SSM Session Manager (no SSH key, no open ports).
#
#   - IAM role/profile "ec2-ssm" (AmazonSSMManagedInstanceCore)   [reused if present]
#   - security group "<NAME>-sg": no inbound, all outbound          [reused if present]
#   - instance tagged Name=<NAME>
#
# Usage:
#   ./scripts/create-ec2.sh NAME [-t TYPE] [-s DISK_GB] [-z AZ] [--delete]
#
#   -t TYPE     instance type            (default t3.medium)
#   -s DISK_GB  root volume size         (default 30)
#   -z AZ       availability zone of the default subnet (default: first one)
#   --delete    terminate NAME and delete its security group
#
# Needs: aws CLI (AWS_PROFILE / AWS_REGION).
set -euo pipefail

NAME=""
TYPE="t3.medium"
DISK=30
AZ=""
DELETE=0
PROFILE_NAME="ec2-ssm"
export AWS_REGION="${AWS_REGION:-eu-central-1}"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--type)   TYPE="$2"; shift 2 ;;
    -s|--size)   DISK="$2"; shift 2 ;;
    -z|--az)     AZ="$2"; shift 2 ;;
    --delete)    DELETE=1; shift ;;
    -h|--help)   usage 0 ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *)  NAME="$1"; shift ;;
  esac
done
[ -n "$NAME" ] || { echo "ERROR: NAME is required" >&2; usage 1; }
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found" >&2; exit 1; }

q() { aws "$@" --output text; }
none() { [ -z "$1" ] || [ "$1" = "None" ]; }
SG_NAME="$NAME-sg"

find_instance() {  # "<id> <public-ip>" of a non-terminated instance named NAME
  q ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[0].Instances[0].[InstanceId,PublicIpAddress]'
}

# --- delete -------------------------------------------------------------------------
if [ "$DELETE" -eq 1 ]; then
  read -r ID _ < <(find_instance)
  if none "${ID:-}"; then
    echo "==> no instance named $NAME"
  else
    aws ec2 terminate-instances --instance-ids "$ID" >/dev/null
    echo "==> terminating $ID ($NAME), waiting..."
    aws ec2 wait instance-terminated --instance-ids "$ID"
  fi
  SG=$(q ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --query 'SecurityGroups[0].GroupId')
  if ! none "$SG"; then
    aws ec2 delete-security-group --group-id "$SG" && echo "==> deleted security group $SG_NAME"
  fi
  exit 0
fi

# --- default VPC + default subnet ---------------------------------------------------------
VPC=$(q ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId')
none "$VPC" && { echo "ERROR: no default VPC in $AWS_REGION" >&2; exit 1; }
FILTERS=("Name=vpc-id,Values=$VPC" "Name=default-for-az,Values=true")
[ -n "$AZ" ] && FILTERS+=("Name=availability-zone,Values=$AZ")
SUBNET=$(q ec2 describe-subnets --filters "${FILTERS[@]}" \
  --query 'sort_by(Subnets,&AvailabilityZone)[0].SubnetId')
none "$SUBNET" && { echo "ERROR: no default subnet found${AZ:+ in $AZ}" >&2; exit 1; }
echo "==> default VPC $VPC, subnet $SUBNET"

# --- IAM profile for SSM ----------------------------------------------------------------
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  echo "==> creating IAM role/profile $PROFILE_NAME (SSM access)"
  aws iam create-role --role-name "$PROFILE_NAME" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$PROFILE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$PROFILE_NAME"
  echo "    waiting 15s for IAM propagation"; sleep 15
fi

# --- security group (no inbound) ----------------------------------------------------------
SG=$(q ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC" \
  --query 'SecurityGroups[0].GroupId')
if none "$SG"; then
  SG=$(q ec2 create-security-group --group-name "$SG_NAME" --description "$NAME" --vpc-id "$VPC" --query GroupId)
  echo "==> created security group $SG_NAME ($SG), no inbound rules"
fi

# --- instance -------------------------------------------------------------------------------
read -r ID PUB < <(find_instance)
if none "${ID:-}"; then
  AMI=$(q ssm get-parameter --query Parameter.Value \
    --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id)
  echo "==> launching $NAME ($TYPE, ${DISK}GB, $AMI)"
  ID=$(q ec2 run-instances --image-id "$AMI" --instance-type "$TYPE" \
    --subnet-id "$SUBNET" --security-group-ids "$SG" --associate-public-ip-address \
    --iam-instance-profile "Name=$PROFILE_NAME" \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1 \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$DISK,VolumeType=gp3,Encrypted=true}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
    --query 'Instances[0].InstanceId')
  aws ec2 wait instance-running --instance-ids "$ID"
  PUB=$(q ec2 describe-instances --instance-ids "$ID" --query 'Reservations[0].Instances[0].PublicIpAddress')
else
  echo "==> $NAME already exists"
fi

cat <<EOF
==> $NAME  id=$ID  public-ip=$PUB
    shell:  aws ssm start-session --target $ID     (or EC2 console -> Connect -> Session Manager)
            SSM needs ~1-2 min after launch to register.
    delete: $0 $NAME --delete
EOF