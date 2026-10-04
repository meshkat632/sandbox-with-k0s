#!/usr/bin/env bash
# install-k3k.sh — install (or upgrade) the K3k controller and the k3kcli binary.
#
# Idempotent: safe to re-run. Installs the Helm chart with `helm upgrade --install`
# and only replaces k3kcli when the version differs.
#
# Steps:
#   1. Preflight: helm, kubectl, a reachable cluster
#   2. Install/upgrade the K3k controller Helm chart into k3k-system
#   3. Wait for the controller Deployment to roll out and the CRD to register
#   4. Install the matching k3kcli binary
#   5. Print the validator command
#
# Usage:  ./install-k3k.sh
# Env overrides:
#   K3K_NS            controller namespace            (default: k3k-system)
#   CHART_VERSION     pin the Helm chart version       (default: latest --devel)
#   K3KCLI_VERSION    pin the k3kcli release tag       (default: latest release)
#   INSTALL_DIR       where to put k3kcli              (default: /usr/local/bin)
#   HELM_REPO_URL     chart repo                       (default: https://rancher.github.io/k3k)
#   SKIP_CLI=1        don't install k3kcli
#   SKIP_CONTROLLER=1 don't touch the Helm release

set -euo pipefail

K3K_NS="${K3K_NS:-k3k-system}"
CHART_VERSION="${CHART_VERSION:-}"
K3KCLI_VERSION="${K3KCLI_VERSION:-}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
HELM_REPO_URL="${HELM_REPO_URL:-https://rancher.github.io/k3k}"
GH_REPO="rancher/k3k"

if [[ -t 1 ]]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi
ok()   { echo "  ${GREEN}OK${RESET}    $*"; }
err()  { echo "  ${RED}ERR${RESET}   $*" >&2; }
note() { echo "  ${YELLOW}..${RESET}   $*"; }
section() { echo; echo "${BOLD}== $*${RESET}"; }
die()  { err "$*"; exit 1; }

# Run a command with sudo only when the target isn't writable as the current user.
maybe_sudo() {
  if [[ -w "$INSTALL_DIR" ]] || [[ "$(id -u)" == "0" ]]; then
    "$@"
  elif command -v sudo >/dev/null; then
    sudo "$@"
  else
    die "need write access to $INSTALL_DIR (set INSTALL_DIR to a writable path, or install sudo)"
  fi
}

# ---------------------------------------------------------------------------
section "1. Preflight"
command -v kubectl >/dev/null || die "kubectl not found in PATH"
CTX=$(kubectl config current-context 2>/dev/null || echo "?")
kubectl get --raw /readyz >/dev/null 2>&1 || die "cannot reach the cluster (context: $CTX)"
ok "cluster reachable (context: $CTX)"

if [[ "${SKIP_CONTROLLER:-0}" != "1" ]]; then
  command -v helm >/dev/null || die "helm not found in PATH (needed for the controller; or set SKIP_CONTROLLER=1)"
  ok "helm $(helm version --short 2>/dev/null || echo present)"
fi

# ---------------------------------------------------------------------------
section "2. K3k controller (Helm)"
if [[ "${SKIP_CONTROLLER:-0}" == "1" ]]; then
  note "SKIP_CONTROLLER=1 — leaving the Helm release untouched"
else
  helm repo add k3k "$HELM_REPO_URL" >/dev/null 2>&1 || true
  helm repo update k3k >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 || true
  ok "chart repo ready ($HELM_REPO_URL)"

  HELM_ARGS=(upgrade --install k3k k3k/k3k --namespace "$K3K_NS" --create-namespace --devel --wait --timeout 5m)
  if [[ -n "$CHART_VERSION" ]]; then
    HELM_ARGS+=(--version "$CHART_VERSION")
    note "pinning chart version $CHART_VERSION"
  fi
  note "running: helm ${HELM_ARGS[*]}"
  if helm "${HELM_ARGS[@]}"; then
    installed=$(helm -n "$K3K_NS" list -o json 2>/dev/null | grep -o '"chart":"[^"]*"' | head -n1 | cut -d'"' -f4)
    ok "controller installed/upgraded (${installed:-k3k})"
  else
    die "helm install failed"
  fi
fi

# ---------------------------------------------------------------------------
section "3. Wait for controller + CRD"
# Roll out whichever deployment carries 'k3k' in its name.
DEPLOY=$(kubectl -n "$K3K_NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -m1 k3k || true)
if [[ -n "$DEPLOY" ]]; then
  if kubectl -n "$K3K_NS" rollout status "deploy/$DEPLOY" --timeout=300s >/dev/null 2>&1; then
    ok "controller Deployment $K3K_NS/$DEPLOY rolled out"
  else
    err "controller Deployment $K3K_NS/$DEPLOY did not become ready in time"
    kubectl -n "$K3K_NS" get pods 2>/dev/null | sed 's/^/        /'
  fi
else
  note "no k3k Deployment found yet in $K3K_NS (SKIP_CONTROLLER set?)"
fi

for _ in $(seq 1 30); do
  kubectl get crd clusters.k3k.io >/dev/null 2>&1 && break
  sleep 2
done
if kubectl get crd clusters.k3k.io >/dev/null 2>&1; then
  ver=$(kubectl get crd clusters.k3k.io -o jsonpath='{.spec.versions[?(@.storage)].name}' 2>/dev/null)
  ok "CRD clusters.k3k.io registered (storage version: ${ver:-?})"
else
  err "CRD clusters.k3k.io not present after waiting — check the controller logs"
fi

# ---------------------------------------------------------------------------
section "4. k3kcli binary"
if [[ "${SKIP_CLI:-0}" == "1" ]]; then
  note "SKIP_CLI=1 — not installing k3kcli"
else
  # Resolve OS/arch for the release asset name.
  os=$(uname -s | tr '[:upper:]' '[:lower:]')   # linux | darwin
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported architecture $(uname -m) for k3kcli" ;;
  esac

  # Resolve the release tag if not pinned.
  if [[ -z "$K3KCLI_VERSION" ]]; then
    K3KCLI_VERSION=$(curl -fsSL "https://api.github.com/repos/${GH_REPO}/releases/latest" 2>/dev/null \
      | grep -m1 '"tag_name"' | cut -d'"' -f4)
    [[ -n "$K3KCLI_VERSION" ]] || die "could not resolve latest k3kcli tag (set K3KCLI_VERSION)"
    note "latest k3kcli release: $K3KCLI_VERSION"
  fi

  # Skip the download if the right version is already in place.
  current=""
  if command -v k3kcli >/dev/null; then
    current=$(k3kcli --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  fi
  if [[ -n "$current" && "$current" == "$K3KCLI_VERSION" ]]; then
    ok "k3kcli $current already installed ($(command -v k3kcli))"
  else
    asset="k3kcli-${os}-${arch}"
    url="https://github.com/${GH_REPO}/releases/download/${K3KCLI_VERSION}/${asset}"
    tmp=$(mktemp)
    note "downloading $url"
    if curl -fsSL -o "$tmp" "$url"; then
      chmod +x "$tmp"
      maybe_sudo mv "$tmp" "$INSTALL_DIR/k3kcli"
      ok "installed k3kcli $K3KCLI_VERSION to $INSTALL_DIR/k3kcli"
    else
      rm -f "$tmp"
      die "download failed: $url (check the tag and asset name on the releases page)"
    fi
  fi
  command -v k3kcli >/dev/null && k3kcli --version 2>/dev/null | sed 's/^/        /' || true
fi

# ---------------------------------------------------------------------------
section "Done"
echo "  Next: validate the install with"
echo "      ./scripts/validate-k3k.sh"