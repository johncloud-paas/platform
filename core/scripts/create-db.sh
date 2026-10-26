#!/usr/bin/env bash
set -Eeuo pipefail

# create-db.sh — database creation mechanism.
#
# This file holds the logic to create a single PostgreSQL database and its
# login role (idempotently). It is meant to be *sourced* by other scripts
# (e.g. configure-core.sh) to reuse provision_database(), but can also be run
# directly as a CLI:
#
#   create-db.sh <db> <user> <password>
#
# It expects to run where psql/pg_isready are available and the server is
# reachable (the core Postgres container, or against PGHOST).
#
# Environment:
#   PGHOST / PGPORT / PGUSER  connection target (default: db / 5432 / postgres)
#   PGPASSWORD                postgres superuser password (required)

: "${PGHOST:=db}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:?Missing PGPASSWORD}"

export PGPASSWORD

# Block until PostgreSQL accepts connections (or give up after ~60s).
wait_for_postgres() {
    local attempt
    for attempt in $(seq 1 30); do
        if pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
            >/dev/null 2>&1; then
            return 0
        fi

        if [ "$attempt" -eq 30 ]; then
            echo "ERROR: PostgreSQL is not available" >&2
            return 1
        fi

        sleep 2
    done
}

# Create a database and its owning login role. Both steps are idempotent, so
# re-running against an already-provisioned server is a no-op.
provision_database() {
    local app_db="$1"
    local app_user="$2"
    local app_password="$3"

    echo "Provisioning database '$app_db'..."

    psql \
        --no-psqlrc \
        --set ON_ERROR_STOP=1 \
        --host="$PGHOST" \
        --port="$PGPORT" \
        --username="$PGUSER" \
        --dbname=postgres \
        --set=app_db="$app_db" \
        --set=app_user="$app_user" \
        --set=app_password="$app_password" <<'SQL'

SELECT format('CREATE ROLE %I LOGIN', :'app_user')
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = :'app_user'
)
\gexec

SELECT format(
    'ALTER ROLE %I WITH LOGIN PASSWORD %L',
    :'app_user',
    :'app_password'
)
\gexec

SELECT format(
    'CREATE DATABASE %I OWNER %I',
    :'app_db',
    :'app_user'
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_database WHERE datname = :'app_db'
)
\gexec

SQL

    echo "Database '$app_db' ready."
}

# When executed directly (not sourced), act as a one-shot CLI.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    app_db="${1:?Usage: $0 <db> <user> <password>}"
    app_user="${2:?Usage: $0 <db> <user> <password>}"
    app_password="${3:?Usage: $0 <db> <user> <password>}"

    wait_for_postgres
    provision_database "$app_db" "$app_user" "$app_password"
fi
