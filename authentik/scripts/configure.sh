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
#   AUTHENTIK_DB_PASSWORD                   password for the authentik role

SCRIPT_DIR="/core-scripts"

# Pull in provision_database() / wait_for_postgres() without running the CLI.
# shellcheck source=create-db.sh
source "$SCRIPT_DIR/create-db.sh"

: "${AUTHENTIK_DB_PASSWORD:?Missing AUTHENTIK_DB_PASSWORD}"

provision_database authentik authentik "$AUTHENTIK_DB_PASSWORD"
