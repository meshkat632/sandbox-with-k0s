#!/usr/bin/env bash
# validate-k3k.sh — check that K3k (virtual clusters) is installed and functional.
#
# Checks:
#   1. Host cluster is reachable
#   2. K3k CRDs are installed (clusters.k3k.io)
#   3. K3k controller Deployment is rolled out
#   4. k3kcli availability (needed for the functional checks)
#   5. A virtual cluster provisions: Cluster resource + server pod Running + Service
#   6. The virtual cluster's API answers (get nodes / version) via its kubeconfig
#   7. A workload deployed INTO the virtual cluster runs; in shared mode it is
#      reflected to a host pod
#
# By default this CREATES a throwaway virtual cluster and deletes it at the end.
# Point it at an existing one with EXISTING_CLUSTER / EXISTING_CLUSTER_NS instead.
#
# Usage:  ./validate-k3k.sh
# Env overrides:
#   K3K_CTRL_NS       controller namespace        (default: auto-detect, else k3k-system)
#   MODE              provisioning mode            (default: shared)
#   TEST_CLUSTER      name of the test cluster     (default: k3k-validate)
#   TEST_CLUSTER_NS   namespace for it             (default: k3k-<TEST_CLUSTER>)
#   EXISTING_CLUSTER  validate this cluster instead of creating one
#   EXISTING_CLUSTER_NS  its namespace
#   IMAGE             workload image for ch.7      (default: busybox:1.36)
#   TIMEOUT           seconds to wait per step     (default: 240)
#   KEEP=1            don't delete the test cluster/namespace at the end

set -uo pipefail

K3K_CTRL_NS="${K3K_CTRL_NS:-}"
MODE="${MODE:-shared}"
TEST_CLUSTER="${TEST_CLUSTER:-k3k-validate}"
TEST_CLUSTER_NS="${TEST_CLUSTER_NS:-k3k-${TEST_CLUSTER}}"
EXISTING_CLUSTER="${EXISTING_CLUSTER:-}"
EXISTING_CLUSTER_NS="${EXISTING_CLUSTER_NS:-}"
IMAGE="${IMAGE:-busybox:1.36}"
TIMEOUT="${TIMEOUT:-240}"

if [[ -t 1 ]]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi

FAILS=0
WARNS=0
pass() { echo "  ${GREEN}PASS${RESET}  $*"; }
fail() { echo "  ${RED}FAIL${RESET}  $*"; FAILS=$((FAILS + 1)); }
warn() { echo "  ${YELLOW}WARN${RESET}  $*"; WARNS=$((WARNS + 1)); }
info() { echo "  INFO  $*"; }
section() { echo; echo "${BOLD}== $*${RESET}"; }

# State that cleanup needs.
CREATED_CLUSTER=0
PF_PID=""
VKUBECONFIG=""
WORKDIR="$(mktemp -d)"

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1
  if [[ "$CREATED_CLUSTER" == "1" && "${KEEP:-0}" != "1" ]]; then
    kubectl -n "$CLUSTER_NS" delete cluster "$CLUSTER_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete namespace "$CLUSTER_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKDIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Poll until the predicate command succeeds, or timeout.
wait_for() {  # $1=timeout  $2..=command
  local to=$1; shift
  local end=$((SECONDS + to))
  while ((SECONDS < end)); do
    "$@" && return 0
    sleep 3
  done
  return 1
}

# ---------------------------------------------------------------------------
section "1. Host cluster access"
if ! command -v kubectl >/dev/null; then
  fail "kubectl not found in PATH"; exit 1
fi
CTX=$(kubectl config current-context 2>/dev/null || echo "?")
if kubectl get --raw /readyz >/dev/null 2>&1; then
  pass "host API server reachable (context: $CTX)"
else
  fail "cannot reach host API server (context: $CTX)"; exit 1
fi

# ---------------------------------------------------------------------------
section "2. K3k CRDs"
if kubectl get crd clusters.k3k.io >/dev/null 2>&1; then
  APIVER=$(kubectl get crd clusters.k3k.io -o jsonpath='{.spec.versions[?(@.storage)].name}' 2>/dev/null)
  APIVER=${APIVER:-v1beta1}
  pass "CRD clusters.k3k.io present (storage version: $APIVER)"
else
  fail "CRD clusters.k3k.io not found — K3k controller not installed"; exit 1
fi
if kubectl get crd virtualclusterpolicies.k3k.io >/dev/null 2>&1; then
  pass "CRD virtualclusterpolicies.k3k.io present"
else
  info "CRD virtualclusterpolicies.k3k.io not present (older K3k, or policies unused)"
fi

# ---------------------------------------------------------------------------
section "3. K3k controller Deployment"
if [[ -z "$K3K_CTRL_NS" ]]; then
  K3K_CTRL_NS=$(kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk '$2 ~ /k3k/ {print $1; exit}')
  K3K_CTRL_NS=${K3K_CTRL_NS:-k3k-system}
fi
CTRL_DEPLOY=$(kubectl -n "$K3K_CTRL_NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -m1 k3k)
if [[ -n "$CTRL_DEPLOY" ]]; then
  avail=$(kubectl -n "$K3K_CTRL_NS" get deploy "$CTRL_DEPLOY" -o jsonpath='{.status.availableReplicas}')
  want=$(kubectl -n "$K3K_CTRL_NS" get deploy "$CTRL_DEPLOY" -o jsonpath='{.spec.replicas}')
  if [[ -n "$avail" && "$avail" == "$want" && "$avail" != "0" ]]; then
    pass "controller $K3K_CTRL_NS/$CTRL_DEPLOY ready ($avail/$want)"
  else
    fail "controller $K3K_CTRL_NS/$CTRL_DEPLOY not ready (${avail:-0}/${want:-0})"
  fi
else
  fail "no K3k controller Deployment found in namespace $K3K_CTRL_NS"
fi

# ---------------------------------------------------------------------------
section "4. k3kcli"
HAVE_CLI=0
if command -v k3kcli >/dev/null; then
  HAVE_CLI=1
  pass "k3kcli found ($(k3kcli --version 2>/dev/null | head -n1 || echo 'version unknown'))"
else
  warn "k3kcli not in PATH — functional checks (5-7) need it; install from the k3k releases"
fi

# ---------------------------------------------------------------------------
section "5. Virtual cluster provisioning"
if [[ -n "$EXISTING_CLUSTER" ]]; then
  CLUSTER_NAME="$EXISTING_CLUSTER"
  CLUSTER_NS="${EXISTING_CLUSTER_NS:-$TEST_CLUSTER_NS}"
  if kubectl -n "$CLUSTER_NS" get cluster "$CLUSTER_NAME" >/dev/null 2>&1; then
    pass "using existing cluster $CLUSTER_NS/$CLUSTER_NAME"
  else
    fail "existing cluster $CLUSTER_NS/$CLUSTER_NAME not found"; CLUSTER_NAME=""
  fi
else
  CLUSTER_NAME="$TEST_CLUSTER"
  CLUSTER_NS="$TEST_CLUSTER_NS"
  kubectl create namespace "$CLUSTER_NS" >/dev/null 2>&1 || true
  if [[ "$HAVE_CLI" == "1" ]]; then
    if k3kcli cluster create "$CLUSTER_NAME" --namespace "$CLUSTER_NS" --mode "$MODE" \
         --timeout "${TIMEOUT}s" >"$WORKDIR/create.log" 2>&1; then
      CREATED_CLUSTER=1; pass "k3kcli created cluster $CLUSTER_NS/$CLUSTER_NAME (mode: $MODE)"
    else
      CREATED_CLUSTER=1  # it may still have created the object; let cleanup handle it
      warn "k3kcli cluster create returned non-zero (see below); continuing to inspect state"
      sed 's/^/          /' "$WORKDIR"/create.log | tail -n 5
    fi
  else
    if kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: k3k.io/$APIVER
kind: Cluster
metadata:
  name: $CLUSTER_NAME
  namespace: $CLUSTER_NS
spec:
  mode: $MODE
EOF
    then
      CREATED_CLUSTER=1; pass "created Cluster $CLUSTER_NS/$CLUSTER_NAME via kubectl (mode: $MODE)"
    else
      fail "could not create Cluster $CLUSTER_NS/$CLUSTER_NAME"
    fi
  fi
fi

# Wait for a server pod to be Running and a Service to exist.
if [[ -n "${CLUSTER_NAME:-}" ]]; then
  server_running() {
    kubectl -n "$CLUSTER_NS" get pods --no-headers 2>/dev/null \
      | awk '$1 ~ /server/ && $3 == "Running" {found=1} END {exit found?0:1}'
  }
  if wait_for "$TIMEOUT" server_running; then
    sp=$(kubectl -n "$CLUSTER_NS" get pods --no-headers 2>/dev/null | awk '$1 ~ /server/ {print $1; exit}')
    pass "server pod Running ($sp)"
  else
    fail "no Running server pod in $CLUSTER_NS after ${TIMEOUT}s"
    kubectl -n "$CLUSTER_NS" get pods 2>/dev/null | sed 's/^/          /' | head -n 6
  fi
  # Pick the Service that exposes the API port (6443), not kube-dns/metrics.
  SVC=$(kubectl -n "$CLUSTER_NS" get svc \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.ports[*].port}{"\n"}{end}' 2>/dev/null \
        | awk '{for(i=2;i<=NF;i++) if($i==6443){print $1; exit}}')
  # Fallbacks: a name ending in -service, else the cluster-named non-dns Service.
  if [[ -z "$SVC" ]]; then
    SVC=$(kubectl -n "$CLUSTER_NS" get svc --no-headers 2>/dev/null \
          | awk '$1 ~ /-service$/ {print $1; exit}')
  fi
  if [[ -z "$SVC" ]]; then
    SVC=$(kubectl -n "$CLUSTER_NS" get svc --no-headers 2>/dev/null \
          | awk '$1 ~ /'"$CLUSTER_NAME"'/ && $1 !~ /dns|metrics/ {print $1; exit}')
  fi
  if [[ -n "$SVC" ]]; then
    pass "virtual cluster API Service present ($SVC)"
  else
    fail "no API Service (port 6443) found in $CLUSTER_NS"
    kubectl -n "$CLUSTER_NS" get svc 2>/dev/null | sed 's/^/          /'
  fi
fi

# ---------------------------------------------------------------------------
section "6. Virtual cluster API reachable"
VK_OK=0
if [[ -n "${CLUSTER_NAME:-}" && -n "${SVC:-}" ]]; then
  # Port-forward the vcluster API to localhost; k3s server certs include 127.0.0.1.
  LPORT=$(( (RANDOM % 20000) + 20000 ))
  SVC_PORT=$(kubectl -n "$CLUSTER_NS" get svc "$SVC" -o jsonpath='{.spec.ports[?(@.port==6443)].port}' 2>/dev/null)
  SVC_PORT=${SVC_PORT:-$(kubectl -n "$CLUSTER_NS" get svc "$SVC" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)}
  kubectl -n "$CLUSTER_NS" port-forward "svc/$SVC" "${LPORT}:${SVC_PORT}" >"$WORKDIR/pf.log" 2>&1 &
  PF_PID=$!
  sleep 4

  VKUBECONFIG="$WORKDIR/vcluster.kubeconfig"
  if [[ "$HAVE_CLI" == "1" ]]; then
    k3kcli kubeconfig generate --namespace "$CLUSTER_NS" --name "$CLUSTER_NAME" \
      --kubeconfig-server "https://127.0.0.1:${LPORT}" --config-name "$VKUBECONFIG" \
      >"$WORKDIR/kcfg.log" 2>&1
    # k3kcli may write to its own default path; find the newest kubeconfig if so.
    [[ -s "$VKUBECONFIG" ]] || VKUBECONFIG=$(grep -oE '/[^ ]+\.(yaml|kubeconfig)' "$WORKDIR"/kcfg.log 2>/dev/null | tail -n1)
  fi

  if [[ -n "$VKUBECONFIG" && -s "$VKUBECONFIG" ]]; then
    vapi_ready() { KUBECONFIG="$VKUBECONFIG" kubectl get --raw /readyz >/dev/null 2>&1; }
    if wait_for 30 vapi_ready; then
      VK_OK=1
      ver=$(KUBECONFIG="$VKUBECONFIG" kubectl version -o json 2>/dev/null | grep -m1 gitVersion | grep -oE 'v[0-9][^"]*')
      nodes=$(KUBECONFIG="$VKUBECONFIG" kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
      pass "virtual cluster API answers (server ${ver:-?}, $nodes node object(s))"
    else
      fail "could not reach virtual cluster API through port-forward (see $WORKDIR/pf.log)"
    fi
  else
    warn "no virtual cluster kubeconfig obtained — skipping API and workload checks (needs k3kcli)"
  fi
fi

# ---------------------------------------------------------------------------
section "7. Workload inside the virtual cluster"
if [[ "$VK_OK" == "1" ]]; then
  tpod="k3k-smoke"
  KUBECONFIG="$VKUBECONFIG" kubectl delete pod "$tpod" --ignore-not-found >/dev/null 2>&1
  KUBECONFIG="$VKUBECONFIG" kubectl run "$tpod" --image="$IMAGE" --restart=Never \
    --command -- sh -c 'echo ok; sleep 20' >/dev/null 2>&1
  phase_running() {
    local p
    p=$(KUBECONFIG="$VKUBECONFIG" kubectl get pod "$tpod" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$p" == "Running" || "$p" == "Succeeded" ]]
  }
  if wait_for "$TIMEOUT" phase_running; then
    pass "workload scheduled and running inside the virtual cluster"
  else
    fail "workload did not reach Running inside the virtual cluster"
    KUBECONFIG="$VKUBECONFIG" kubectl get pod "$tpod" 2>/dev/null | sed 's/^/          /'
  fi

  if [[ "$MODE" == "shared" ]]; then
    # In shared mode the virtual kubelet reflects the pod to a host pod in the
    # cluster namespace, with a name derived from pod/namespace/cluster.
    reflected() {
      kubectl -n "$CLUSTER_NS" get pods --no-headers 2>/dev/null | grep -q "$tpod"
    }
    if wait_for 60 reflected; then
      hp=$(kubectl -n "$CLUSTER_NS" get pods --no-headers 2>/dev/null | grep "$tpod" | awk '{print $1; exit}')
      pass "pod reflected to host as $hp (shared mode)"
    else
      warn "workload not found reflected in host namespace $CLUSTER_NS — check virtual kubelet"
    fi
  else
    info "mode=$MODE: workload runs on the virtual cluster's own agents, not reflected to host"
  fi

  KUBECONFIG="$VKUBECONFIG" kubectl delete pod "$tpod" --ignore-not-found --wait=false >/dev/null 2>&1
else
  info "skipped (virtual cluster API not reachable)"
fi

# ---------------------------------------------------------------------------
echo
if ((FAILS == 0)); then
  echo "${GREEN}${BOLD}All checks passed${RESET} ($WARNS warnings)"
  exit 0
else
  echo "${RED}${BOLD}$FAILS check(s) failed${RESET}, $WARNS warning(s)"
  exit 1
fi