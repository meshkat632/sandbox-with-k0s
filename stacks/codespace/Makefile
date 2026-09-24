TF       ?= terraform
PLAN     ?= tfplan
ENV_FILE ?= .env
# Extra args, e.g. make plan VARS="-var name_suffix=demo01"
VARS     ?=

# Repo layout: this Makefile lives in <repo>/stacks/codespace
REPO_ROOT   := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
SECRET_UTIL := $(REPO_ROOT)/scripts/secret-util.sh
SECRETS     ?= stacks/codespace/secrets.yaml

# SSH / kubectl access to the instance
SSH_KEY      ?= $(HOME)/.ssh/codespace_ed25519
SSH_USER     ?= ubuntu
KUBE_CONTEXT ?= codespace

# kubeconfig comes from Secrets Manager (no Terraform needed); keep in sync with
# var.kubeconfig_secret_name / var.region
KUBECONFIG_SECRET ?= codespace-kubeconfig
REGION            ?= eu-central-1

# Python virtualenv for scripts/ssm_kubectl_apply.py (created on first use)
VENV   := $(REPO_ROOT)/.venv
DEPLOY := $(VENV)/bin/python $(REPO_ROOT)/scripts/ssm_kubectl_apply.py

# Every recipe line runs in a fresh shell, so source the env file (auto-export) per command
LOAD_ENV := set -a && . ./$(ENV_FILE) && set +a
RUN      := $(LOAD_ENV) && $(TF)

# Instance id + region from terraform outputs, for the aws CLI targets
EC2 := ID=$$($(RUN) output -raw instance_id) && R=$$($(RUN) output -raw region) && $(LOAD_ENV)

.DEFAULT_GOAL := help

.PHONY: help env init fmt lint validate plan apply destroy output clean decrypt encrypt ssh kubeconfig deploy status stop start

help: ## Show available targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

env: ## Check that the env file exists
	@test -f $(ENV_FILE) || { echo "ERROR: $(ENV_FILE) not found"; exit 1; }

init: env ## Download providers/modules
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

destroy: env ## Destroy all resources
	$(RUN) destroy $(VARS)

output: env ## Show outputs, including sensitive ones
	$(RUN) output -json

decrypt: env ## Decrypt the SOPS secrets file
	@echo "decrypt $(SECRETS)"
	set -a && . ./$(ENV_FILE) && set +a && cd $(REPO_ROOT) && $(SECRET_UTIL) decrypt $(SECRETS)

encrypt: env ## Encrypt the SOPS secrets file
	@echo "encrypt $(SECRETS)"
	set -a && . ./$(ENV_FILE) && set +a && cd $(REPO_ROOT) && $(SECRET_UTIL) encrypt $(SECRETS)

ssh: env ## SSH into the instance
	@IP=$$($(RUN) output -raw public_ip) && \
	ssh -i $(SSH_KEY) -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$IP

kubeconfig: ## Fetch kubeconfig from Secrets Manager and make it the current context (no Terraform)
	@set -e; \
	if [ -f $(ENV_FILE) ]; then set -a; . ./$(ENV_FILE); set +a; fi; \
	TMP=$$(mktemp -d); trap 'rm -rf "$$TMP"' EXIT; chmod 700 "$$TMP"; \
	echo "Fetching kubeconfig from secret $(KUBECONFIG_SECRET) ($(REGION)) ..."; \
	aws secretsmanager get-secret-value --region $(REGION) --secret-id $(KUBECONFIG_SECRET) \
	  --query SecretString --output text > "$$TMP/remote"; \
	K="kubectl --kubeconfig $$TMP/remote config view --raw -o"; \
	SERVER=$$($$K jsonpath='{.clusters[0].cluster.server}' 2> /dev/null) && [ -n "$$SERVER" ] || \
	  { echo "ERROR: secret $(KUBECONFIG_SECRET) holds no kubeconfig yet - did 'make apply' finish?"; exit 1; }; \
	$$K jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$$TMP/ca.crt"; \
	$$K jsonpath='{.users[0].user.client-certificate-data}'         | base64 -d > "$$TMP/client.crt"; \
	$$K jsonpath='{.users[0].user.client-key-data}'                  | base64 -d > "$$TMP/client.key"; \
	kubectl config set-cluster $(KUBE_CONTEXT) --server=$$SERVER \
	  --certificate-authority="$$TMP/ca.crt" --embed-certs=true > /dev/null; \
	kubectl config set-credentials $(KUBE_CONTEXT) \
	  --client-certificate="$$TMP/client.crt" --client-key="$$TMP/client.key" --embed-certs=true > /dev/null; \
	kubectl config set-context $(KUBE_CONTEXT) --cluster=$(KUBE_CONTEXT) --user=$(KUBE_CONTEXT) > /dev/null; \
	kubectl config use-context $(KUBE_CONTEXT); \
	kubectl get nodes --request-timeout=10s || \
	  { echo "API not reachable at $$SERVER - is port 6443 open in the security group?"; exit 1; }

# Stamp file, not bin/python: that is a symlink to the system interpreter
$(VENV)/.installed: $(REPO_ROOT)/scripts/requirements.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -r $<
	@touch $@

deploy: env $(VENV)/.installed ## Apply MANIFEST (file or dir) through SSM, no SSH/6443 needed; NAMESPACE=, DRY_RUN=1
	@test -n "$(MANIFEST)" || { echo "usage: make deploy MANIFEST=path.yaml [NAMESPACE=apps] [DRY_RUN=1]"; exit 1; }
	@$(LOAD_ENV) && $(DEPLOY) --region $(REGION) $(if $(NAMESPACE),--namespace $(NAMESPACE)) $(if $(DRY_RUN),--dry-run) $(MANIFEST)

status: env ## Show instance state and IP
	@$(EC2) && aws ec2 describe-instances --region $$R --instance-ids $$ID \
	  --query 'Reservations[0].Instances[0].[InstanceId,InstanceType,State.Name,PublicIpAddress]' --output text

stop: env ## Stop the instance (disk, Elastic IP and TF state are kept)
	@$(EC2) && echo "Stopping $$ID ..." && \
	aws ec2 stop-instances --region $$R --instance-ids $$ID > /dev/null && \
	aws ec2 wait instance-stopped --region $$R --instance-ids $$ID && echo "$$ID stopped"

start: env ## Start the instance and wait until SSH and Kubernetes respond
	@$(EC2) && IP=$$($(RUN) output -raw public_ip) && echo "Starting $$ID ..." && \
	aws ec2 start-instances --region $$R --instance-ids $$ID > /dev/null && \
	aws ec2 wait instance-running --region $$R --instance-ids $$ID && \
	echo "Running - waiting for SSH and Kubernetes on $$IP ..." && \
	for i in $$(seq 1 36); do \
	  if ssh -i $(SSH_KEY) -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
	       $(SSH_USER)@$$IP 'kubectl get nodes --request-timeout=5s' 2> /dev/null | grep -q ' Ready'; then \
	    echo "Ready: ssh $(SSH_USER)@$$IP"; exit 0; \
	  fi; sleep 5; \
	done; echo "ERROR: not ready after 3 minutes (try: make ssh)"; exit 1

clean: ## Remove local plan and .terraform cache
	rm -rf .terraform $(PLAN)