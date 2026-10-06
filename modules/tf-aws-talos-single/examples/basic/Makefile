.PHONY: kubeconfig kubeconfig-install nodes

KUBECONFIG_FILE := kubeconfig.yaml
KUBECONFIG_DIR  ?= $(HOME)/.kube/configs

# Write the cluster's admin kubeconfig next to this Makefile
kubeconfig:
	@umask 077; terraform output -raw kubeconfig > $(KUBECONFIG_FILE)
	@chmod 600 $(KUBECONFIG_FILE)
	@echo "Wrote $(KUBECONFIG_FILE) - export KUBECONFIG=$(CURDIR)/$(KUBECONFIG_FILE)"

# Install it as its own file in the per-cluster kubeconfig folder
# (<cluster name>.yaml), where the shell's KUBECONFIG picks it up.
kubeconfig-install: kubeconfig
	@mkdir -p $(KUBECONFIG_DIR)
	@name=$$(kubectl --kubeconfig $(KUBECONFIG_FILE) config view -o jsonpath='{.clusters[0].name}'); \
		install -m 600 $(KUBECONFIG_FILE) $(KUBECONFIG_DIR)/$$name.yaml; \
		echo "Installed $(KUBECONFIG_DIR)/$$name.yaml - context $$(kubectl --kubeconfig $(KUBECONFIG_FILE) config current-context)"

nodes: kubeconfig
	@kubectl --kubeconfig $(KUBECONFIG_FILE) get nodes -o wide
