# Shortcuts for the talos-ec2 stack. Optional: every target only calls
# ./kubeconfig.sh or ./addons.sh, which work without make.

.DEFAULT_GOAL := help

CLUSTER        := $(shell sed -n 's/^  name: *//p' cluster.yaml | head -1)
KUBECONFIG_DIR ?= $(HOME)/.kube/configs

# make addons ADDONS="traefik cert-manager" overrides the list in cluster.yaml
ADDONS ?=

.PHONY: help kubeconfig nodes clean addons metrics-server node-exporter kube-state-metrics local-storage prometheus loki traefik cert-manager wildcard-cert error-pages letsencrypt hello-world grafana

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-19s\033[0m %s\n", $$1, $$2}'

kubeconfig: ## Fetch the admin kubeconfig from the cluster (Talos API) into ~/.kube/configs/<cluster name>.yaml
	@./kubeconfig.sh

nodes: kubeconfig ## kubectl get nodes with the fetched kubeconfig
	@kubectl --kubeconfig "$(KUBECONFIG_DIR)/$(CLUSTER).yaml" get nodes -o wide

# The state lives in Terraform Cloud; these are leftovers from local runs.
# A local state that still tracks resources is kept unless FORCE=1.
clean: ## Remove local Terraform state files (terraform.tfstate*), not the state in Terraform Cloud
	@if [ -f terraform.tfstate ] && grep -q '"type":' terraform.tfstate && [ "$(FORCE)" != "1" ]; then \
		echo "ERROR: terraform.tfstate still tracks resources; deleting it would orphan them." >&2; \
		echo "       Destroy or migrate them first, or run: make clean FORCE=1" >&2; \
		exit 1; \
	fi
	@files="$$(ls terraform.tfstate terraform.tfstate.* 2>/dev/null || true)"; \
	if [ -z "$$files" ]; then echo "No local state files"; exit 0; fi; \
	rm -f $$files && echo "Removed:" && echo "$$files" | sed 's/^/  /'

addons: ## Install the add-ons selected in cluster.yaml, in dependency order
	@./addons.sh $(ADDONS)

metrics-server: ## Install metrics-server (kubectl top, HPA)
	@./addons.sh $@

node-exporter: ## Install the Prometheus node exporter (node metrics on port 9100)
	@./addons.sh $@

kube-state-metrics: ## Install kube-state-metrics (object state as Prometheus metrics)
	@./addons.sh $@

local-storage: ## Install the default StorageClass on the fixed-size data disk
	@./addons.sh $@

prometheus: ## Install Prometheus (server only, data on the default StorageClass)
	@./addons.sh $@

loki: ## Install Loki and the Alloy log collector (pod logs, 7 days)
	@./addons.sh $@

traefik: ## Install Traefik on ports 80/443 of every node (default ingress class)
	@./addons.sh $@

cert-manager: ## Install cert-manager (controller and CRDs, no issuers)
	@./addons.sh $@

wildcard-cert: ## Issue a wildcard certificate (local CA) and make it Traefik's default
	@./addons.sh $@

error-pages: ## Deploy the default error pages (catch-all 404, opt-in 5xx middleware)
	@./addons.sh $@

letsencrypt: ## Create the Let's Encrypt issuers (HTTP-01 through Traefik, needs port 80 open)
	@./addons.sh $@

hello-world: ## Deploy a hello-world page with an Ingress and a Let's Encrypt certificate
	@./addons.sh $@

grafana: ## Install Grafana (Prometheus + Loki datasources) with an Ingress and a Let's Encrypt certificate
	@./addons.sh $@
