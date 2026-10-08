#!/usr/bin/env bash
# Install cluster add-ons: one, several, or the ones selected in cluster.yaml.
# Plain bash - this is what `terraform apply` runs, and make is not needed.
#
# Usage:
#   ./addons.sh                       the add-ons listed in cluster.yaml
#   ./addons.sh traefik               one add-on
#   ./addons.sh traefik cert-manager  several
#   ./addons.sh --all                 every add-on
#   ./addons.sh --list                show the add-ons and the selection
#
# Whatever the order of the arguments, the add-ons are installed in dependency
# order, after fetching the kubeconfig (./kubeconfig.sh). Each one is a script
# in addons/ that is idempotent and can also be run directly once the
# kubeconfig is there. The first failure stops the run.
#
# Needs aws, talosctl, kubectl, helm and git in PATH.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")" && pwd)"

# In dependency order: Prometheus, Loki and Grafana need the StorageClass; the
# certificates, pages and Grafana's Ingress need Traefik and cert-manager
ALL_ADDONS=(
  metrics-server node-exporter kube-state-metrics local-storage prometheus loki
  traefik cert-manager wildcard-cert error-pages letsencrypt hello-world grafana
)

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# spec.addons.install in cluster.yaml: one "- name" per line, "#" skips a line
from_cluster_yaml() {
  sed -n '/^ *install:/,/^ *[a-zA-Z]/s/^ *- *\([a-z-]*\).*/\1/p' "$STACK_DIR/cluster.yaml"
}

contains() {
  local wanted="$1" item
  shift
  for item in "$@"; do
    [ "$item" = "$wanted" ] && return 0
  done
  return 1
}

list=0
requested=()
explicit=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --list)    list=1 ;;
    --all)     requested=("${ALL_ADDONS[@]}"); explicit=1 ;;
    -*)        echo "Unknown option: $1" >&2; usage 1 ;;
    *)         requested+=("$1"); explicit=1 ;;
  esac
  shift
done

if [ "$explicit" -eq 0 ]; then
  mapfile -t requested < <(from_cluster_yaml)
fi

for addon in "${requested[@]}"; do
  contains "$addon" "${ALL_ADDONS[@]}" \
    || { echo "ERROR: unknown add-on: $addon (known: ${ALL_ADDONS[*]})" >&2; exit 1; }
done

if [ "$list" -eq 1 ]; then
  for addon in "${ALL_ADDONS[@]}"; do
    if contains "$addon" "${requested[@]}"; then echo "[x] $addon"; else echo "[ ] $addon"; fi
  done
  exit 0
fi

if [ "${#requested[@]}" -eq 0 ]; then
  echo "No add-ons selected in cluster.yaml"
  exit 0
fi

missing=()
for bin in aws "${TALOSCTL:-talosctl}" kubectl helm git; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: not found in PATH: ${missing[*]}" >&2
  echo "       The add-ons are installed from the machine that runs this script." >&2
  exit 1
fi

"$STACK_DIR/kubeconfig.sh"

for addon in "${ALL_ADDONS[@]}"; do
  contains "$addon" "${requested[@]}" || continue
  echo
  echo "### $addon"
  "$STACK_DIR/addons/$addon.sh"
done
