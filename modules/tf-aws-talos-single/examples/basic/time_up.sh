#!/usr/bin/env bash
# Create the cluster and record how long it takes until Kubernetes is usable:
# node Ready, all kube-system pods Ready and CoreDNS rolled out.
# Appends one row per run to timings.csv.
set -euo pipefail

KUBECONFIG_FILE="${KUBECONFIG_FILE:-kubeconfig.yaml}"
TIMINGS_FILE="${TIMINGS_FILE:-timings.csv}"
READY_TIMEOUT="${READY_TIMEOUT:-600}"

k() { kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=10s "$@"; }

cluster_ready() {
  k wait --for=condition=Ready nodes --all --timeout=10s &&
    k -n kube-system rollout status deployment/coredns --timeout=10s &&
    k -n kube-system wait --for=condition=Ready pods --all --timeout=10s
}

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start=$(date +%s)

terraform apply -auto-approve -input=false
applied=$(date +%s)

(umask 077; terraform output -raw kubeconfig > "$KUBECONFIG_FILE")
chmod 600 "$KUBECONFIG_FILE"

echo "Waiting for the cluster to become ready (timeout ${READY_TIMEOUT}s)..."
until cluster_ready >/dev/null 2>&1; do
  if (( $(date +%s) - applied > READY_TIMEOUT )); then
    echo "Cluster not ready after ${READY_TIMEOUT}s - nothing recorded" >&2
    exit 1
  fi
  sleep 2
done
ready=$(date +%s)

k8s_version=$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
os_image=$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}')

[ -f "$TIMINGS_FILE" ] ||
  echo "started_at_utc,apply_seconds,ready_seconds,total_seconds,kubernetes,os_image" > "$TIMINGS_FILE"
echo "$started_at,$((applied - start)),$((ready - applied)),$((ready - start)),$k8s_version,$os_image" >> "$TIMINGS_FILE"

echo
echo "terraform apply:    $((applied - start))s"
echo "apply -> ready:     $((ready - applied))s"
echo "total to usable:    $((ready - start))s   (recorded in $TIMINGS_FILE)"
