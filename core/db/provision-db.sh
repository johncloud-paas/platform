
#!/usr/bin/env bash
set -Eeuo pipefail

: "${PGHOST:=db}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:?Missing PGPASSWORD}"

export PGPASSWORD

# Wait for PostgreSQL to become available.
for attempt in $(seq 1 30); do
    if pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
        >/dev/null 2>&1; then
        break
    fi

    if [ "$attempt" -eq 30 ]; then
        echo "ERROR: PostgreSQL is not available" >&2
        exit 1
    fi

    sleep 2
done

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

: "${DOCKHAND_DB_PASSWORD:?Missing DOCKHAND_DB_PASSWORD}"
: "${PANGOLIN_DB_PASSWORD:?Missing PANGOLIN_DB_PASSWORD}"

provision_database dockhand dockhand "$DOCKHAND_DB_PASSWORD"
provision_database pangolin pangolin "$PANGOLIN_DB_PASSWORD"

echo "All databases provisioned successfully."
