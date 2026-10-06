#!/usr/bin/env bash
# Create the cluster and record how long it takes until Kubernetes is usable:
# every node Ready, all kube-system pods Ready and CoreDNS rolled out.
# Appends one row per run to timings.csv.
set -euo pipefail

TIMINGS_FILE="${TIMINGS_FILE:-timings.csv}"
READY_TIMEOUT="${READY_TIMEOUT:-600}"

k() { kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=10s "$@"; }

ready_nodes() { k get nodes --no-headers | awk '$2 == "Ready"' | wc -l; }

cluster_ready() {
  [ "$(ready_nodes)" -eq "$expected_nodes" ] &&
    k -n kube-system rollout status deployment/coredns --timeout=10s &&
    k -n kube-system wait --for=condition=Ready pods --all --timeout=10s
}

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start=$(date +%s)

terraform apply -auto-approve -input=false
applied=$(date +%s)

KUBECONFIG_FILE=$(./install_kubeconfig.sh)
expected_nodes=$(terraform output -raw node_count)

echo "Waiting for $expected_nodes node(s) to become ready (timeout ${READY_TIMEOUT}s)..."
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
  echo "started_at_utc,apply_seconds,ready_seconds,total_seconds,kubernetes,os_image,nodes" > "$TIMINGS_FILE"
echo "$started_at,$((applied - start)),$((ready - applied)),$((ready - start)),$k8s_version,$os_image,$expected_nodes" >> "$TIMINGS_FILE"

echo
echo "terraform apply:    $((applied - start))s"
echo "apply -> ready:     $((ready - applied))s"
echo "total to usable:    $((ready - start))s   (recorded in $TIMINGS_FILE)"
