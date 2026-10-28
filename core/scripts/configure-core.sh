#!/usr/bin/env bash
set -Eeuo pipefail

# configure-core.sh — main database provisioning entrypoint.
#
# Instantiates the fixed platform databases (dockhand, pangolin) by reusing the
# creation mechanism from create-db.sh. The compose `initial-config` service
# runs this inside the core Postgres image against the `db` service.
#
# Environment:
#   PGHOST / PGPORT / PGUSER / PGPASSWORD  superuser connection (see create-db.sh)
#   DOCKHAND_DB_PASSWORD                   password for the dockhand role
#   PANGOLIN_DB_PASSWORD                   password for the pangolin role

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pull in provision_database() / wait_for_postgres() without running the CLI.
# shellcheck source=create-db.sh
source "$SCRIPT_DIR/create-db.sh"

: "${DOCKHAND_DB_PASSWORD:?Missing DOCKHAND_DB_PASSWORD}"
: "${PANGOLIN_DB_PASSWORD:?Missing PANGOLIN_DB_PASSWORD}"

wait_for_postgres

provision_database dockhand dockhand "$DOCKHAND_DB_PASSWORD"
provision_database pangolin pangolin "$PANGOLIN_DB_PASSWORD"

echo "All databases provisioned successfully."

: "${HOST:?Missing HOST}"
: "${EMAIL_HOST:?Missing EMAIL_HOST}"
: "${EMAIL_PORT:?Missing EMAIL_PORT}"
: "${EMAIL_USERNAME:?Missing EMAIL_USERNAME}"
: "${EMAIL_LETS_ENCRYPT:?Missing EMAIL_LETS_ENCRYPT}"

# Build the routed-domain blocks from the comma-separated ROUTED_DOMAINS env var.
# domain1 is reserved for $HOST, so numbering starts at domain2.
ROUTED_DOMAINS_BLOCKS=""
i=2
IFS=',' read -ra _routed <<< "$ROUTED_DOMAINS"
for d in "${_routed[@]}"; do
    d="$(echo "$d" | xargs)"   # trim surrounding whitespace
    [ -z "$d" ] && continue
    ROUTED_DOMAINS_BLOCKS+="  domain${i}:"$'\n'
    ROUTED_DOMAINS_BLOCKS+="    base_domain: \"${d}\""$'\n'
    ROUTED_DOMAINS_BLOCKS+="    cert_resolver: \"letsencrypt\""$'\n'
    i=$((i + 1))
done
export ROUTED_DOMAINS_BLOCKS

# The postgres:alpine image has no envsubst; it ships in gettext.
command -v envsubst >/dev/null 2>&1 || apk add --no-cache gettext

(
    mkdir -p /pangolin /traefik/GeoLite2 /traefik/agent/positions /traefik/dashboard /traefik/plugins /traefik/conf.d/rules &&
    envsubst < /pangolin_src/config.template.yml        > /pangolin/config.yml &&
    envsubst < /traefik_src/dynamic_config.template.yml > /traefik/conf.d/rules/dynamic_config.yml &&
    envsubst < /traefik_src/static_config.template.yml  > /traefik/conf.d/static_config.yml
)
