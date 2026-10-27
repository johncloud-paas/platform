#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
cd "$SCRIPT_DIR"

set -a; source .env; set +a

mkdir -p "${JOHNCLOUD_ROOT}/teleport/data"

envsubst '$CLUSTER_NAME $HOST' < config/teleport.template.yaml > config/teleport.yaml
