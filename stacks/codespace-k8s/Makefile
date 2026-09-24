TF       ?= terraform
PLAN     ?= tfplan
# Shares the codespace stack's env file (AWS_PROFILE); only AWS credentials are needed here
ENV_FILE ?= ../codespace/.env
# Extra args, e.g. make plan VARS='-var namespaces=["apps","tools"]'
VARS     ?=

# Every recipe line runs in a fresh shell, so source the env file (auto-export) per command
LOAD_ENV := set -a && . $(ENV_FILE) && set +a
RUN      := $(LOAD_ENV) && $(TF)

.DEFAULT_GOAL := help

.PHONY: help env init fmt lint validate plan apply destroy output clean

help: ## Show available targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

env: ## Check that the env file exists
	@test -f $(ENV_FILE) || { echo "ERROR: $(ENV_FILE) not found"; exit 1; }

init: env ## Download providers
	$(RUN) init -upgrade

fmt: ## Format all .tf files
	$(TF) fmt -recursive

lint: ## Check formatting and validate without credentials or a backend (CI-safe)
	$(TF) fmt -recursive -check -diff
	$(TF) init -backend=false -input=false > /dev/null
	$(TF) validate

validate: init ## Check syntax and config
	$(RUN) validate

plan: validate ## Create an execution plan
	$(RUN) plan $(VARS) -out=$(PLAN)

apply: env ## Apply the saved plan (run 'make plan' first)
	$(RUN) apply $(PLAN)

destroy: env ## Destroy the namespaces (and everything in them)
	$(RUN) destroy $(VARS)

output: env ## Show outputs
	$(RUN) output

clean: ## Remove local plan and .terraform cache
	rm -rf .terraform $(PLAN)
