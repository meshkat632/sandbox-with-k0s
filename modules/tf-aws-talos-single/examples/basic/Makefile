.PHONY: kubeconfig nodes timed-up timings

# Copy the cluster's admin kubeconfig to ~/.kube/configs/<cluster name>.yaml
# (override the folder with KUBECONFIG_DIR=...)
kubeconfig:
	@echo "Installed $$(./install_kubeconfig.sh)"

nodes:
	@kubectl --kubeconfig "$$(./install_kubeconfig.sh)" get nodes -o wide

# terraform apply (auto-approved) + wait until Kubernetes is usable;
# appends the durations to timings.csv
timed-up:
	@./time_up.sh

timings:
	@column -s, -t timings.csv
