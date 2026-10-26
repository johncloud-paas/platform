#!/bin/bash
#
# startstack.sh — deploy a stack with secrets injected from Infisical.
#
# Usage: ./startstack.sh <stack-dir> <infisical-env> [service]
#   <stack-dir>       subfolder containing the stack's docker-compose.yml
#   <infisical-env>   Infisical environment slug (e.g. prod, dev)
#   [service]         optional service whose logs are tailed after launch
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <stack-dir> <infisical-env> [service]" >&2
  exit 1
fi

STACK_DIR_ARG="$1"
INFISICAL_ENV="$2"
SERVICE="${3:-}"

SERVICE_DIR="$(readlink -f "$STACK_DIR_ARG")"
if [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  echo "Error: no docker-compose.yml in $SERVICE_DIR" >&2
  exit 1
fi

# Infisical secret path is the stack's folder name under the project root.
INFISICAL_PATH="/$(basename "$SERVICE_DIR")"

run() {
  infisical run --env="$INFISICAL_ENV" --path="$INFISICAL_PATH" -- "$@"
}

(
  cd "$SERVICE_DIR" &&
  run docker compose pull &&
  run docker compose down &&
  run docker compose up -d --force-recreate --remove-orphans &&
  run docker compose logs -f $SERVICE
)
