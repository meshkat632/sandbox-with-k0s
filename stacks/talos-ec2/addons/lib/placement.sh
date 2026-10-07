# Sourced by the add-on scripts: where their pods are allowed to run.
#
# Every node is tainted, so nothing is scheduled by default:
#   control plane   node-role.kubernetes.io/control-plane:NoSchedule
#   workers         cluster.local/role=worker:NoSchedule
#
# The add-ons are cluster services and run on the control plane nodes. The
# per-node agents (ingress controller, node exporter, log collector) run on
# every node. The values are JSON, which is also valid inside a YAML manifest.

# shellcheck disable=SC2034  # used by the scripts that source this file
CONTROL_PLANE_SELECTOR='{"node-role.kubernetes.io/control-plane":""}'
CONTROL_PLANE_TOLERATIONS='[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]'
ALL_NODES_TOLERATIONS='[{"operator":"Exists","effect":"NoSchedule"}]'
