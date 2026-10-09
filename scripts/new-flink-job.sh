#!/usr/bin/env bash
# Create a new Flink job from flink-basics/flink-job-template with its own groupId/artifactId.
#
#   mkflink <groupId> <artifactId> [target-dir]
#
# Same arguments and behaviour as new-java-project.sh, just a different template.
#
# Install as a command:  ln -s "$(realpath scripts/new-flink-job.sh)" ~/.local/bin/mkflink
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
TEMPLATE_DIR="$SCRIPT_DIR/../flink-basics/flink-job-template" CMD_NAME=mkflink \
    exec "$SCRIPT_DIR/new-java-project.sh" "$@"
