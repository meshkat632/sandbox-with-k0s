# Local housekeeping for the k3k-host Terraform project.
#
# The real state lives in HCP Terraform (cloud block), so nothing here touches it.
# bootstrap-oidc/terraform.tfstate is the ONLY copy of that state and is never deleted.

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -ec
.DEFAULT_GOAL := help

TF ?= terraform

# Local-only files that are safe to delete (recreated by `terraform init` / `plan`)
CACHE_DIRS  := .terraform
CACHE_FILES := *.tfplan tfplan crash.log crash.*.log

.PHONY: help clean clean-all init fmt validate plan apply kubeconfig allow-ip

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

clean: ## Remove local caches: .terraform/, plan files, crash logs (keeps lock file)
	@echo "==> Removing local Terraform caches"
	rm -rf $(CACHE_DIRS)
	rm -f $(CACHE_FILES)
	@echo "    done. Run 'make init' (or terraform init) before the next plan."

clean-all: ## clean + lock file + stray local *.tfstate* in this folder (asks first)
	@echo "This also removes:"
	ls -1d .terraform .terraform.lock.hcl *.tfstate* *.tfplan tfplan crash*.log 2>/dev/null | sort -u | sed 's/^/    /' || true
	echo "    (remote state in HCP Terraform and bootstrap-oidc/ state are NOT touched)"
	read -r -p "Continue? [y/N] " ans
	if [[ "$$ans" != [yY] ]]; then echo "aborted, nothing removed"; exit 0; fi
	rm -rf $(CACHE_DIRS)
	rm -f $(CACHE_FILES) .terraform.lock.hcl *.tfstate *.tfstate.backup
	echo "==> Clean. Run 'make init' to re-download providers and recreate the lock file."

init: ## terraform init
	$(TF) init

fmt: ## terraform fmt -recursive
	$(TF) fmt -recursive

validate: ## terraform validate
	$(TF) validate

plan: ## terraform plan
	$(TF) plan

apply: ## terraform apply
	$(TF) apply

kubeconfig: ## Write ~/.kube/configs/k3k-host.yaml from Secrets Manager
	./scripts/get-kubeconfig.sh

allow-ip: ## Whitelist your current public IP on the security group
	./scripts/allow-my-ip.sh