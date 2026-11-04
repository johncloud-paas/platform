#!/usr/bin/env bash
set -Eeuo pipefail

# Provisions the `monitoring` database + role (reusing create-db.sh) and applies
# the telemetry schema (logs + metrics tables) that Vector writes into. The compose
# `initial-config` service runs this inside the core Postgres image against the
# shared `db` service (reachable cross-stack as core-db-1).
#
# Environment:
#   PGHOST / PGPORT / PGUSER / PGPASSWORD  superuser connection (see create-db.sh)
#   MONITORING_DB_PASSWORD                   password for the monitoring role

SCRIPT_DIR="/scripts"

# Pull in provision_database() / wait_for_postgres() without running the CLI.
# shellcheck source=create-db.sh
source "$SCRIPT_DIR/create-db.sh"

: "${MONITORING_DB_PASSWORD:?Missing MONITORING_DB_PASSWORD}"

wait_for_postgres
provision_database monitoring monitoring "$MONITORING_DB_PASSWORD"

# Apply the telemetry schema as the monitoring role, so the tables are owned by it
# (Vector logs in as monitoring and needs to INSERT). Idempotent DDL.
echo "Applying monitoring schema..."
PGPASSWORD="$MONITORING_DB_PASSWORD" psql \
    --no-psqlrc \
    --set ON_ERROR_STOP=1 \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username=monitoring \
    --dbname=monitoring \
    -f "$SCRIPT_DIR/schema.sql"
echo "Monitoring schema ready."

