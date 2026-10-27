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

# Timestamped, colorized step logging on stderr.
log() {
  printf '\033[1;36m[startstack %s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

STACK_DIR_ARG="$1"
INFISICAL_ENV="$2"
SERVICE="${3:-}"

SERVICE_DIR="$(readlink -f "$STACK_DIR_ARG")"
if [ ! -f "$SERVICE_DIR/docker-compose.yml" ]; then
  echo "Error: no docker-compose.yml in $SERVICE_DIR" >&2
  exit 1
fi

log "Stack: $(basename "$SERVICE_DIR") ($SERVICE_DIR)"
log "Infisical env: $INFISICAL_ENV"

# Infisical secret path is the stack's folder name under the project root.
INFISICAL_PATH="/$(basename "$SERVICE_DIR")"

# Pull this stack's secrets from Infisical once and load them into the
# environment, so every docker compose call below inherits them without
# re-contacting Infisical.
log "Loading secrets from Infisical"
_INFISICAL_STDERR="$(mktemp)"
if SECRETS="$(infisical export --env="$INFISICAL_ENV" --path="$INFISICAL_PATH" --format=dotenv-export 2>"$_INFISICAL_STDERR")"; then
  if [ -z "$SECRETS" ]; then
    log "No secrets found in Infisical for path $INFISICAL_PATH (env: $INFISICAL_ENV) — continuing without injected secrets"
  else
    eval "$SECRETS"
  fi
elif grep -qE "404|was not found" "$_INFISICAL_STDERR"; then
  log "No secrets folder found in Infisical for path $INFISICAL_PATH (env: $INFISICAL_ENV) — continuing without injected secrets"
else
  cat "$_INFISICAL_STDERR" >&2
  rm -f "$_INFISICAL_STDERR"
  exit 1
fi
rm -f "$_INFISICAL_STDERR"
unset SECRETS

# Traefik's shared network name is read from the stack's .env (not Infisical).
if [ -f "$SERVICE_DIR/.env" ]; then
  TRAEFIK_NETWORK="$(grep -E '^TRAEFIK_NETWORK=' "$SERVICE_DIR/.env" | tail -n1 | cut -d= -f2-)"
fi

(
  cd "$SERVICE_DIR" &&

  if [ -n "${TRAEFIK_NETWORK:-}" ]; then
    if docker network inspect "$TRAEFIK_NETWORK" >/dev/null 2>&1; then
      log "Network '$TRAEFIK_NETWORK' already exists — skipping"
    else
      log "Creating bridge network '$TRAEFIK_NETWORK'"
      docker network create -d bridge "$TRAEFIK_NETWORK"
    fi
  else
    log "No TRAEFIK_NETWORK in .env — skipping network creation"
  fi &&

  log "Pulling images" &&
  docker compose pull &&

  log "Stopping existing containers" &&
  docker compose down &&

  if [ -f "$SERVICE_DIR/setup_before_up.sh" ]; then
    log "Running setup_before_up.sh" &&
    bash "$SERVICE_DIR/setup_before_up.sh"
  fi &&

  log "Starting containers (remove-orphans)" &&
  docker compose up -d --remove-orphans &&

  log "Tailing logs${SERVICE:+ for $SERVICE} (Ctrl-C to detach)" &&
  docker compose logs -f $SERVICE
)
