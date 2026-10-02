#!/usr/bin/env bash
# Install Kata Containers with the upstream kata-deploy Helm chart, through K3s's
# built-in Helm controller: this script only drops a HelmChart manifest on the server.
#
# kata-deploy then runs on every node labelled kata=true (the Kata worker pools),
# installs the Kata binaries there, registers the runtime with K3s's containerd and
# labels the node katacontainers.io/kata-runtime=true. Pods opt in with
#   runtimeClassName: kata        (or kata-qemu)
# and are scheduled onto those nodes only.
#
# Installed and run on each server by the SSM association in kata.tf; safe to re-run.
# Manual re-run on a server:
#   sudo KATA_VERSION=4.2.0 bash /usr/local/bin/install-kata.sh
set -euo pipefail

: "${KATA_VERSION:?}"

MANIFEST=/var/lib/rancher/k3s/server/manifests/kata-deploy.yaml
k() { k3s kubectl "$@"; }

# --- 1. A new server may still be installing K3s --------------------------------
for _ in $(seq 1 120); do
  k get --raw /readyz >/dev/null 2>&1 && break
  sleep 10
done
k get --raw /readyz >/dev/null 2>&1 || { echo "ERROR: K3s API is not ready" >&2; exit 1; }

# --- 2. Write the HelmChart manifest; K3s applies it by itself -------------------
helm_job() { k -n kube-system get job helm-install-kata-deploy -o "jsonpath={$1}" 2>/dev/null || true; }
OLD_JOB="$(helm_job .metadata.uid)"
NEW="$(mktemp)"
trap 'rm -f "$NEW"' EXIT
cat >"$NEW" <<EOF
# Managed by Terraform (SSM association); edits are overwritten.
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: kata-deploy
  namespace: kube-system
spec:
  chart: oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy
  version: "${KATA_VERSION}"
  targetNamespace: kube-system
  valuesContent: |-
    k8sDistribution: k3s
    # Only the Kata worker pools; they are the ones with KVM.
    nodeSelector:
      kata: "true"
    # One hypervisor (QEMU). RuntimeClasses: kata-qemu, plus "kata" as the default name.
    shims:
      disableAll: true
      qemu:
        enabled: true
        # Keep the pod's VM (QEMU, virtiofsd, the shim) inside the pod's own cgroup. With
        # Kata's default (false) that cgroup stays empty under K3s's systemd cgroup driver,
        # the kubelet finds it gone and kills the pod a second after it starts; pods
        # without resource requests were hit almost every time.
        dropIn: |
          [runtime]
          sandbox_cgroup_only = true
    defaultShim:
      amd64: qemu
    runtimeClasses:
      createDefault: true
    # No extra image snapshotter; plain Kata uses containerd's default.
    snapshotter:
      setup: []
EOF

if cmp -s "$NEW" "$MANIFEST"; then
  echo "==> $MANIFEST unchanged"
else
  install -m 600 "$NEW" "$MANIFEST"
  echo "==> wrote $MANIFEST (kata-deploy ${KATA_VERSION})"

  # K3s runs a fresh helm-install job for the changed manifest; wait for that one.
  echo "==> waiting for the Helm job"
  ok=0
  for _ in $(seq 1 90); do
    if [ -n "$(helm_job .metadata.uid)" ] && [ "$(helm_job .metadata.uid)" != "$OLD_JOB" ] \
       && [ "$(helm_job .status.succeeded)" = "1" ]; then
      ok=1
      break
    fi
    sleep 10
  done
  if [ "$ok" != 1 ]; then
    echo "ERROR: the helm-install-kata-deploy job did not complete" >&2
    k -n kube-system get helmchart,job,pod 2>&1 | grep -i kata >&2 || true
    exit 1
  fi
fi

# --- 3. Wait until this version is installed -------------------------------------
echo "==> waiting for the chart to install"
installed=""
for _ in $(seq 1 90); do
  installed="$(k get runtimeclass kata-qemu -o jsonpath='{.metadata.annotations.katacontainers\.io/kata-version}' 2>/dev/null || true)"
  [ "$installed" = "$KATA_VERSION" ] && break
  sleep 10
done
if [ "$installed" != "$KATA_VERSION" ]; then
  echo "ERROR: kata-deploy ${KATA_VERSION} did not install (RuntimeClass kata-qemu reports '${installed}')" >&2
  k -n kube-system get helmchart,job,pod 2>&1 | grep -i kata >&2 || true
  exit 1
fi

# Rolls out to the Kata nodes that have joined so far (returns at once if there are none);
# nodes that join later are picked up by the DaemonSet on their own.
k -n kube-system rollout status daemonset/kata-deploy --timeout=900s
k get runtimeclass
echo "==> done"
