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
#   MONITORING_RO_DB_USER                    name of the read-only login role
#   MONITORING_RO_DB_PASSWORD                password for the read-only role

SCRIPT_DIR="/scripts"

# Pull in provision_database() / wait_for_postgres() without running the CLI.
# shellcheck source=create-db.sh
source "$SCRIPT_DIR/create-db.sh"

: "${MONITORING_DB_PASSWORD:?Missing MONITORING_DB_PASSWORD}"
: "${MONITORING_RO_DB_USER:?Missing MONITORING_RO_DB_USER}"
: "${MONITORING_RO_DB_PASSWORD:?Missing MONITORING_RO_DB_PASSWORD}"

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

# Provision a read-only login role for query/dashboard consumers (e.g. Grafana).
# Run as the superuser against the monitoring DB so we can both CREATE ROLE and
# set default privileges on behalf of the `monitoring` owner. All steps are
# idempotent, so re-running is a no-op.
echo "Provisioning read-only role '$MONITORING_RO_DB_USER'..."
psql \
    --no-psqlrc \
    --set ON_ERROR_STOP=1 \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$PGUSER" \
    --dbname=monitoring \
    --set=app_db=monitoring \
    --set=app_user=monitoring \
    --set=ro_user="$MONITORING_RO_DB_USER" \
    --set=ro_password="$MONITORING_RO_DB_PASSWORD" <<'SQL'

SELECT format('CREATE ROLE %I LOGIN', :'ro_user')
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = :'ro_user'
)
\gexec

SELECT format(
    'ALTER ROLE %I WITH LOGIN PASSWORD %L',
    :'ro_user',
    :'ro_password'
)
\gexec

-- Allow connecting to the database and reading the public schema.
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'app_db', :'ro_user')
\gexec

SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'ro_user')
\gexec

-- Read access to every existing table/view in public.
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', :'ro_user')
\gexec

-- And to any table the `monitoring` owner creates in public later on.
SELECT format(
    'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public '
    'GRANT SELECT ON TABLES TO %I',
    :'app_user',
    :'ro_user'
)
\gexec

SQL
echo "Read-only role '$MONITORING_RO_DB_USER' ready."

