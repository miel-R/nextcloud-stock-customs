#!/bin/bash
# Create the n8n database + login role inside the SAME Postgres instance that
# serves Nextcloud. Runs only ONCE, on the first initialization of the
# nextcloud_db volume (postgres runs /docker-entrypoint-initdb.d/*.sh exactly
# once on an empty data dir).
#
# Values come from the N8N_DB_* env vars set on the nextcloud-db service
# (compose.db.yaml). n8n then connects with:
#   DB_POSTGRESDB_HOST=nextcloud-db
#   DB_POSTGRESDB_DATABASE=$N8N_DB_NAME
#   DB_POSTGRESDB_USER=$N8N_DB_USER
#   DB_POSTGRESDB_PASSWORD=$N8N_DB_PASSWORD
set -euo pipefail

: "${N8N_DB_NAME:-n8n}"
: "${N8N_DB_USER:-n8n}"

# No password -> n8n not configured; skip so first DB init still succeeds.
if [ -z "${N8N_DB_PASSWORD:-}" ]; then
    echo "N8N_DB_PASSWORD not set - skipping n8n database provisioning (ok if you are not using n8n)."
    exit 0
fi

# Create the login role if it does not already exist.
if ! psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -tAc "SELECT 1 FROM pg_roles WHERE rolname='$N8N_DB_USER'" | grep -q 1; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -c "CREATE ROLE \"$N8N_DB_USER\" LOGIN PASSWORD '$N8N_DB_PASSWORD';"
fi

# Create the database (owned by the role) if it does not already exist.
if ! psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -tAc "SELECT 1 FROM pg_database WHERE datname='$N8N_DB_NAME'" | grep -q 1; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -c "CREATE DATABASE \"$N8N_DB_NAME\" OWNER \"$N8N_DB_USER\";"
fi