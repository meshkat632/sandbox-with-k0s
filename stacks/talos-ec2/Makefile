# Local helpers for the talos-ec2 stack.
#
# Nothing here runs Terraform or reads its state: the cluster name and region
# come from cluster.yaml, credentials from AWS (SSM Parameter Store).

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

TALOSCTL ?= talosctl

CLUSTER := $(shell sed -n 's/^  name: *//p' cluster.yaml | head -1)
REGION  := $(shell sed -n 's/^ *region: *//p' cluster.yaml | head -1)

# One cluster per file, picked up by kubectl from ~/.kube/configs/*.yaml
KUBECONFIG_DIR ?= $(HOME)/.kube/configs
KUBECONFIG_OUT := $(KUBECONFIG_DIR)/$(CLUSTER).yaml

# How long make kubeconfig waits for the API server after a fresh apply
WAIT_SECONDS ?= 300

# Talos client config, published by the talos module
TALOSCONFIG_PARAM ?= /talos/$(CLUSTER)/talosconfig

.PHONY: help kubeconfig nodes metrics-server

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

kubeconfig: ## Fetch the admin kubeconfig from the instance (Talos API) into ~/.kube/configs/<cluster name>.yaml
	@for bin in aws $(TALOSCTL); do
		command -v "$$bin" >/dev/null || { echo "ERROR: '$$bin' not found in PATH" >&2; exit 1; }
	done
	tmp="$$(mktemp -d)"
	trap 'rm -rf "$$tmp"' EXIT
	aws ssm get-parameter --region "$(REGION)" --name "$(TALOSCONFIG_PARAM)" --with-decryption \
		--query Parameter.Value --output text > "$$tmp/talosconfig"
	# Talos has no SSH: the node hands out a fresh kubeconfig over its API (port 50000)
	$(TALOSCTL) --talosconfig "$$tmp/talosconfig" kubeconfig "$$tmp/kubeconfig" --merge=false
	mkdir -p "$(KUBECONFIG_DIR)"
	install -m 600 "$$tmp/kubeconfig" "$(KUBECONFIG_OUT)"
	echo "Wrote $(KUBECONFIG_OUT)"
	# Right after an apply the node is still starting the control plane
	echo "Waiting for the API server (up to $(WAIT_SECONDS)s)"
	deadline=$$(( $$(date +%s) + $(WAIT_SECONDS) ))
	until kubectl --kubeconfig "$(KUBECONFIG_OUT)" --request-timeout=5s get --raw /readyz >/dev/null 2>&1; do
		if [ "$$(date +%s)" -ge "$$deadline" ]; then
			echo "ERROR: API server not ready after $(WAIT_SECONDS)s" >&2
			kubectl --kubeconfig "$(KUBECONFIG_OUT)" --request-timeout=5s get --raw /readyz >&2 || true
			exit 1
		fi
		sleep 5
	done
	echo "API server is ready"

nodes: kubeconfig ## kubectl get nodes with the fetched kubeconfig
	@kubectl --kubeconfig "$(KUBECONFIG_OUT)" get nodes -o wide

metrics-server: kubeconfig ## Install metrics-server (kubectl top, HPA)
	@./addons/metrics-server.sh
