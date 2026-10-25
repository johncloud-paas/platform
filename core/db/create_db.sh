#!/usr/bin/env bash
set -Eeuo pipefail

# create_db.sh <db> <user> <password>
#
# Create a single application database and its login role, the same way
# provision-db.sh bootstraps the fixed platform databases. It reuses the
# provision_database() function straight out of provision-db.sh (so the SQL
# lives in exactly one place) and runs it inside the core Postgres container,
# mirroring the `provision-database` compose service.
#
# provision-db.sh is treated as read-only and is never modified.
#
# Environment:
#   PGPASSWORD / CORE_DB_PASSWORD  postgres superuser password (required)
#   CORE_DB_CONTAINER             target container (default: core-db-1)

usage() {
    echo "Usage: $0 <db> <user> <password>" >&2
    exit 1
}

app_db="${1:-}";       [ -n "$app_db" ]       || usage
app_user="${2:-}";     [ -n "$app_user" ]     || usage
app_password="${3:-}"; [ -n "$app_password" ] || usage

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="${CORE_DB_CONTAINER:-core-db-1}"

: "${PGPASSWORD:=${CORE_DB_PASSWORD:-}}"
if [ -z "$PGPASSWORD" ]; then
    echo "ERROR: set PGPASSWORD (or CORE_DB_PASSWORD) to the postgres superuser password" >&2
    exit 1
fi
export PGPASSWORD

# Pull *only* the function definition out of provision-db.sh, so we reuse its
# exact logic without running its three-database main block.
provision_fn="$(sed -n '/^provision_database()/,/^}/p' "$SCRIPT_DIR/provision-db.sh")"
if [ -z "$provision_fn" ]; then
    echo "ERROR: could not find provision_database() in provision-db.sh" >&2
    exit 1
fi

# Run the reused function inside the Postgres container (psql lives there, and
# the server is reachable on localhost). PGPASSWORD is forwarded via `docker
# exec -e`; the function reads PGHOST/PGPORT/PGUSER, which default correctly.
{
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' ': "${PGHOST:=localhost}" "${PGPORT:=5432}" "${PGUSER:=postgres}"'
    printf '%s\n' "$provision_fn"
    printf 'provision_database %q %q %q\n' "$app_db" "$app_user" "$app_password"
} | docker exec -i -e PGPASSWORD "$CONTAINER" bash -s
