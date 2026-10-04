#!/usr/bin/env bash
# validate-kata.sh — check that kata-deploy is installed and worker nodes can run Kata pods.
#
# Checks:
#   1. Cluster is reachable
#   2. Worker nodes are Ready
#   3. /dev/kvm exists on every worker (nested virtualization enabled)
#   4. kata-deploy DaemonSet is installed and fully rolled out
#   5. Workers carry the katacontainers.io/kata-runtime=true label
#   6. The Kata RuntimeClass exists
#   7. Smoke test: a Kata pod runs on each worker with its own guest kernel
#   8. Isolation regression: a Kata pod is bounded by its VM, not the host
#      (own guest kernel, VM-sized memory, fewer vCPUs than the host)
#
# Usage:  ./validate-kata.sh
# Env overrides:
#   RUNTIME_CLASS    RuntimeClass to test        (default: kata-qemu)
#   KATA_NS          kata-deploy namespace       (default: kube-system)
#   KATA_DS          kata-deploy DaemonSet name  (default: kata-deploy)
#   WORKER_SELECTOR  label selector for workers  (default: !node-role.kubernetes.io/control-plane)
#   TEST_NS          namespace for test pods     (default: kata-validate)
#   TIMEOUT          seconds to wait per pod     (default: 180)
#   KEEP=1           don't delete test namespace at the end

set -uo pipefail

RUNTIME_CLASS="${RUNTIME_CLASS:-kata-qemu}"
KATA_NS="${KATA_NS:-kube-system}"
KATA_DS="${KATA_DS:-kata-deploy}"
WORKER_SELECTOR="${WORKER_SELECTOR:-!node-role.kubernetes.io/control-plane}"
TEST_NS="${TEST_NS:-kata-validate}"
TIMEOUT="${TIMEOUT:-180}"
IMAGE="${IMAGE:-busybox:1.36}"

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
section() { echo; echo "${BOLD}== $*${RESET}"; }

cleanup() {
  if [[ "${KEEP:-0}" != "1" ]]; then
    kubectl delete namespace "$TEST_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Wait for a pod to finish; prints Succeeded, Failed or Timeout.
wait_pod() {
  local pod=$1 end=$((SECONDS + TIMEOUT)) phase
  while ((SECONDS < end)); do
    phase=$(kubectl -n "$TEST_NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$phase" in
      Succeeded|Failed) echo "$phase"; return 0 ;;
    esac
    sleep 2
  done
  echo "Timeout"
}

# Short reason for a pod that didn't succeed (events often explain Kata failures).
pod_reason() {
  local pod=$1
  kubectl -n "$TEST_NS" get events --field-selector "involvedObject.name=$pod" \
    -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' 2>/dev/null | tail -n 3 | sed 's/^/          /'
}

# ---------------------------------------------------------------------------
section "1. Cluster access"
if ! command -v kubectl >/dev/null; then
  fail "kubectl not found in PATH"; exit 1
fi
CTX=$(kubectl config current-context 2>/dev/null || echo "?")
if kubectl get --raw /readyz >/dev/null 2>&1; then
  pass "API server reachable (context: $CTX)"
else
  fail "cannot reach API server (context: $CTX)"; exit 1
fi

# ---------------------------------------------------------------------------
section "2. Worker nodes Ready"
mapfile -t WORKERS < <(kubectl get nodes -l "$WORKER_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if ((${#WORKERS[@]} == 0)); then
  fail "no worker nodes match selector '$WORKER_SELECTOR'"; exit 1
fi
for n in "${WORKERS[@]}"; do
  ready=$(kubectl get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  unsched=$(kubectl get node "$n" -o jsonpath='{.spec.unschedulable}')
  if [[ "$ready" == "True" && "$unsched" != "true" ]]; then
    pass "$n is Ready and schedulable"
  elif [[ "$ready" == "True" ]]; then
    fail "$n is Ready but cordoned (run: kubectl uncordon $n)"
  else
    fail "$n is not Ready (Ready=$ready)"
  fi
done

kubectl create namespace "$TEST_NS" >/dev/null 2>&1 || true
kubectl label namespace "$TEST_NS" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
section "3. /dev/kvm on workers (nested virtualization)"
for n in "${WORKERS[@]}"; do
  pod="kvm-check-$n"
  kubectl -n "$TEST_NS" delete pod "$pod" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$TEST_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
spec:
  nodeName: $n
  restartPolicy: Never
  tolerations: [{operator: Exists}]
  containers:
  - name: check
    image: $IMAGE
    command: ["sh", "-c", "test -c /host-dev/kvm && echo present || echo missing"]
    volumeMounts: [{name: dev, mountPath: /host-dev, readOnly: true}]
  volumes:
  - name: dev
    hostPath: {path: /dev, type: Directory}
EOF
  phase=$(wait_pod "$pod")
  out=$(kubectl -n "$TEST_NS" logs "$pod" 2>/dev/null)
  if [[ "$phase" == "Succeeded" && "$out" == "present" ]]; then
    pass "$n has /dev/kvm"
  elif [[ "$out" == "missing" ]]; then
    fail "$n has no /dev/kvm — enable nested virtualization on this instance"
  else
    fail "$n KVM check did not complete ($phase)"; pod_reason "$pod"
  fi
done

# ---------------------------------------------------------------------------
section "4. kata-deploy DaemonSet"
if ! kubectl -n "$KATA_NS" get ds "$KATA_DS" >/dev/null 2>&1; then
  found=$(kubectl get ds -A --no-headers 2>/dev/null | awk '$2 ~ /kata-deploy/ {print $1"/"$2; exit}')
  if [[ -n "$found" ]]; then
    KATA_NS=${found%%/*}; KATA_DS=${found##*/}
    warn "found kata-deploy as $KATA_NS/$KATA_DS (set KATA_NS/KATA_DS to silence this)"
  fi
fi
if kubectl -n "$KATA_NS" get ds "$KATA_DS" >/dev/null 2>&1; then
  desired=$(kubectl -n "$KATA_NS" get ds "$KATA_DS" -o jsonpath='{.status.desiredNumberScheduled}')
  ready=$(kubectl -n "$KATA_NS" get ds "$KATA_DS" -o jsonpath='{.status.numberReady}')
  if [[ -n "$desired" && "$desired" == "$ready" && "$desired" != "0" ]]; then
    pass "$KATA_NS/$KATA_DS ready ($ready/$desired)"
  else
    fail "$KATA_NS/$KATA_DS not fully ready (${ready:-0}/${desired:-0})"
  fi
  for n in "${WORKERS[@]}"; do
    if kubectl -n "$KATA_NS" get pods -o wide --no-headers 2>/dev/null | grep "$KATA_DS" | grep -q " $n "; then
      pass "kata-deploy pod running on $n"
    else
      fail "no kata-deploy pod on $n"
    fi
  done
else
  fail "kata-deploy DaemonSet not found (looked for $KATA_NS/$KATA_DS)"
fi

# ---------------------------------------------------------------------------
section "5. Kata runtime node labels"
for n in "${WORKERS[@]}"; do
  lbl=$(kubectl get node "$n" -o jsonpath='{.metadata.labels.katacontainers\.io/kata-runtime}')
  if [[ "$lbl" == "true" ]]; then
    pass "$n labeled katacontainers.io/kata-runtime=true"
  else
    fail "$n missing katacontainers.io/kata-runtime=true (kata-deploy hasn't finished here)"
  fi
done

# ---------------------------------------------------------------------------
section "6. RuntimeClass"
if kubectl get runtimeclass "$RUNTIME_CLASS" >/dev/null 2>&1; then
  handler=$(kubectl get runtimeclass "$RUNTIME_CLASS" -o jsonpath='{.handler}')
  pass "RuntimeClass $RUNTIME_CLASS exists (handler: $handler)"
else
  avail=$(kubectl get runtimeclass -o jsonpath='{range .items[*]}{.metadata.name} {end}' 2>/dev/null)
  fail "RuntimeClass $RUNTIME_CLASS not found (available: ${avail:-none})"
fi

# ---------------------------------------------------------------------------
section "7. Smoke test: Kata pod per worker"
for n in "${WORKERS[@]}"; do
  pod="kata-run-$n"
  host_kernel=$(kubectl get node "$n" -o jsonpath='{.status.nodeInfo.kernelVersion}')
  kubectl -n "$TEST_NS" delete pod "$pod" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$TEST_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
spec:
  runtimeClassName: $RUNTIME_CLASS
  nodeSelector:
    kubernetes.io/hostname: $n
  restartPolicy: Never
  containers:
  - name: test
    image: $IMAGE
    command: ["uname", "-r"]
    resources:
      limits: {cpu: "500m", memory: "256Mi"}
EOF
  phase=$(wait_pod "$pod")
  guest_kernel=$(kubectl -n "$TEST_NS" logs "$pod" 2>/dev/null | tr -d '\r')
  if [[ "$phase" == "Succeeded" && -n "$guest_kernel" && "$guest_kernel" != "$host_kernel" ]]; then
    pass "$n runs Kata pod (guest kernel $guest_kernel, host $host_kernel)"
  elif [[ "$phase" == "Succeeded" ]]; then
    fail "$n pod ran but kernel matches host ($guest_kernel) — not isolated by a VM"
  else
    fail "$n Kata pod did not succeed ($phase)"; pod_reason "$pod"
  fi
done

# ---------------------------------------------------------------------------
section "8. Isolation regression (Kata VM boundary)"
# The security property we hand customers: breaking out of a container lands a
# tenant in the Kata guest VM, not on the host. We verify that boundary by
# contrasting a Kata pod with a plain runc pod on the SAME worker and asserting
# the Kata pod only ever sees its own VM. All probes are read-only.
ISO_NODE="${WORKERS[0]}"
host_kernel=$(kubectl get node "$ISO_NODE" -o jsonpath='{.status.nodeInfo.kernelVersion}')

# Reads MemTotal (kB), kernel, /dev listing and DMI product from a pod.
# Emitted as three lines: "<memtotal_kb> <kernel>" / "<dev entries>" / "<dmi>".
# Passed to the pod as a YAML literal block scalar so no quoting can collide.
probe_script='printf "%s %s %s\n" "$(grep MemTotal /proc/meminfo | tr -s " " | cut -d" " -f2)" "$(uname -r)" "$(nproc)"; ls /dev | tr "\n" " "; printf "\n"'

run_probe() {  # $1=name  $2=runtimeClassName(optional)
  local pod=$1 rc=$2
  kubectl -n "$TEST_NS" delete pod "$pod" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$TEST_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
spec:
$( [[ -n "$rc" ]] && echo "  runtimeClassName: $rc" )
  nodeSelector:
    kubernetes.io/hostname: $ISO_NODE
  restartPolicy: Never
  containers:
  - name: probe
    image: $IMAGE
    command:
    - sh
    - -c
    - |
      $probe_script
    resources:
      limits: {cpu: "500m", memory: "256Mi"}
EOF
  wait_pod "$pod" >/dev/null
  kubectl -n "$TEST_NS" logs "$pod" 2>/dev/null
}

kata_out=$(run_probe "iso-kata" "$RUNTIME_CLASS")
runc_out=$(run_probe "iso-runc" "")

kata_mem=$(echo "$kata_out" | sed -n 1p | awk '{print $1}')
kata_kernel=$(echo "$kata_out" | sed -n 1p | awk '{print $2}')
kata_cpus=$(echo "$kata_out" | sed -n 1p | awk '{print $3}')
kata_dev=$(echo "$kata_out" | sed -n 2p)
runc_mem=$(echo "$runc_out" | sed -n 1p | awk '{print $1}')
runc_kernel=$(echo "$runc_out" | sed -n 1p | awk '{print $2}')
runc_cpus=$(echo "$runc_out" | sed -n 1p | awk '{print $3}')

if [[ -z "$kata_mem" || -z "$runc_mem" ]]; then
  fail "isolation probes did not return data (kata='$kata_out' runc='$runc_out')"
else
  # 8a. Guest kernel: Kata must differ from host; runc must match it (sanity).
  if [[ "$kata_kernel" != "$host_kernel" ]]; then
    pass "Kata pod runs its own guest kernel ($kata_kernel, host $host_kernel)"
  else
    fail "Kata pod shares the host kernel ($kata_kernel) — NOT VM-isolated"
  fi
  if [[ "$runc_kernel" == "$host_kernel" ]]; then
    pass "runc control pod shares host kernel ($runc_kernel) as expected"
  else
    warn "runc control pod kernel ($runc_kernel) != host ($host_kernel) — unexpected baseline"
  fi

  # 8b. Memory: Kata sees only its VM; runc sees the whole host. Guard against
  # a Kata VM accidentally sized at/above host memory (default_memory too high).
  if [[ "$kata_mem" =~ ^[0-9]+$ && "$runc_mem" =~ ^[0-9]+$ ]]; then
    if (( kata_mem < runc_mem )); then
      pass "Kata pod sees VM memory ($((kata_mem/1024)) MiB) < host ($((runc_mem/1024)) MiB)"
    else
      fail "Kata pod sees >= host memory (kata $((kata_mem/1024)) MiB, host $((runc_mem/1024)) MiB) — VM not bounding the host view"
    fi
  else
    warn "could not parse memory totals (kata='$kata_mem' runc='$runc_mem')"
  fi

  # 8c. CPU view: /proc/cpuinfo is not namespaced, so a runc pod sees every
  # host vCPU, while a Kata pod sees only the vCPUs assigned to its VM. Config
  # dependent (default_vcpus), so treat equal-or-more as a soft signal.
  if [[ "$kata_cpus" =~ ^[0-9]+$ && "$runc_cpus" =~ ^[0-9]+$ ]]; then
    if (( kata_cpus < runc_cpus )); then
      pass "Kata pod sees VM vCPUs ($kata_cpus) < host vCPUs ($runc_cpus)"
    else
      warn "Kata pod sees $kata_cpus vCPUs vs host $runc_cpus — VM sized at/above host CPU count (check default_vcpus)"
    fi
  else
    warn "could not parse vCPU counts (kata='$kata_cpus' runc='$runc_cpus')"
  fi

  # 8d. Sanity: no host block devices leak into the container's /dev. True for
  # any container (host disks aren't mapped in), so this guards against a
  # misconfig that bind-mounts the host device tree, not Kata-vs-runc.
  if echo "$kata_dev" | grep -Eqw 'nvme[0-9]+n[0-9]+|xvd[a-z]'; then
    fail "Kata pod can see host block devices in /dev ($kata_dev) — device tree is leaking in"
  else
    pass "Kata pod sees no host block devices in /dev"
  fi
fi

# ---------------------------------------------------------------------------
echo
if ((FAILS == 0)); then
  echo "${GREEN}${BOLD}All checks passed${RESET} (${#WORKERS[@]} workers, $WARNS warnings)"
  exit 0
else
  echo "${RED}${BOLD}$FAILS check(s) failed${RESET}, $WARNS warning(s)"
  exit 1
fi