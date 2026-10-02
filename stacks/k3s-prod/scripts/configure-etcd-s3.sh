#!/usr/bin/env bash
# Make K3s snapshot etcd on a schedule and upload every snapshot to S3.
#
# Installed and run on each server by the SSM association in etcd-backup.tf; safe to
# re-run. Settings come from the environment (see below). S3 credentials come from the
# instance profile, so none are stored on the node.
#
# Manual re-run on a node:
#   sudo ETCD_S3_BUCKET=... ETCD_S3_REGION=... ETCD_S3_FOLDER=... \
#        ETCD_SNAPSHOT_CRON='0 */6 * * *' ETCD_SNAPSHOT_RETENTION=28 \
#        bash /usr/local/bin/configure-etcd-s3.sh
set -euo pipefail

: "${ETCD_S3_BUCKET:?}" "${ETCD_S3_REGION:?}" "${ETCD_S3_FOLDER:?}"
: "${ETCD_SNAPSHOT_CRON:?}" "${ETCD_SNAPSHOT_RETENTION:?}"

CONF_DIR=/etc/rancher/k3s/config.yaml.d
CONF="$CONF_DIR/10-etcd-s3.yaml"

wait_ready() {
  for _ in $(seq 1 60); do
    k3s kubectl get --raw /readyz >/dev/null 2>&1 && return 0
    sleep 5
  done
  echo "ERROR: K3s API did not become ready" >&2
  return 1
}

# --- 1. A new node may still be installing K3s -----------------------------------
for _ in $(seq 1 60); do
  systemctl is-active --quiet k3s && break
  sleep 10
done
systemctl is-active --quiet k3s || { echo "ERROR: k3s is not running" >&2; exit 1; }
wait_ready

# --- 2. Write the config drop-in, restart K3s only if it changed -----------------
mkdir -p "$CONF_DIR"
NEW="$(mktemp)"
trap 'rm -f "$NEW"' EXIT
cat >"$NEW" <<EOF
# Managed by Terraform (SSM association); edits are overwritten.
etcd-s3: true
etcd-s3-bucket: "${ETCD_S3_BUCKET}"
etcd-s3-region: "${ETCD_S3_REGION}"
etcd-s3-folder: "${ETCD_S3_FOLDER}"
etcd-snapshot-schedule-cron: "${ETCD_SNAPSHOT_CRON}"
etcd-snapshot-retention: ${ETCD_SNAPSHOT_RETENTION}
EOF

# The first-boot script installed a cron job taking local-only snapshots that were
# never pruned; K3s's own schedule (above) replaces it.
rm -f /etc/cron.d/k3s-snapshot

if cmp -s "$NEW" "$CONF"; then
  echo "==> $CONF unchanged"
else
  install -m 600 "$NEW" "$CONF"
  echo "==> wrote $CONF, restarting k3s"
  systemctl restart k3s
  wait_ready
fi

# --- 3. Prove the whole path works (config, IAM, bucket) -------------------------
echo "==> taking a snapshot to s3://${ETCD_S3_BUCKET}/${ETCD_S3_FOLDER}"
k3s etcd-snapshot save --name config-check
if ! k3s etcd-snapshot ls 2>/dev/null | grep 'config-check' | grep -q "s3://${ETCD_S3_BUCKET}/"; then
  echo "ERROR: the snapshot did not reach s3://${ETCD_S3_BUCKET}/${ETCD_S3_FOLDER}" >&2
  exit 1
fi
k3s etcd-snapshot prune --name config-check --snapshot-retention 2 \
  || echo "WARN: could not prune old config-check snapshots" >&2
echo "==> done"
