#!/bin/bash
#
# logstack.sh — tail a stack's logs with secrets injected from Infisical.
#
# Usage: ./logstack.sh <stack-dir> <infisical-env> [service]
#   <stack-dir>       subfolder containing the stack's docker-compose.yml
#   <infisical-env>   Infisical environment slug (e.g. prod, dev)
#   [service]         optional service whose logs are tailed
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <stack-dir> <infisical-env> [service]" >&2
  exit 1
fi

# Timestamped, colorized step logging on stderr.
log() {
  printf '\033[1;36m[logstack %s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

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

log "Stack: $(basename "$SERVICE_DIR") ($SERVICE_DIR)"
log "Infisical env: $INFISICAL_ENV"

# Pull this stack's secrets from Infisical once and load them into the
# environment, so every docker compose call below inherits them without
# re-contacting Infisical.
log "Loading secrets from Infisical"
SECRETS="$(infisical export --env="$INFISICAL_ENV" --path="$INFISICAL_PATH" --format=dotenv-export)"
eval "$SECRETS"
unset SECRETS

(
  cd "$SERVICE_DIR" &&

  log "Tailing logs${SERVICE:+ for $SERVICE} (Ctrl-C to detach)" &&
  docker compose logs -f $SERVICE
)
