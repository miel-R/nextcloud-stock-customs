#!/bin/bash
# Create the n8n database + login role inside the SAME Postgres instance that
# serves Nextcloud. Runs only ONCE, on the first initialization of the
# nextcloud_db volume (postgres runs /docker-entrypoint-initdb.d/*.sh exactly
# once on an empty data dir).
#
# The n8n role is a SEPARATE role ("n8n") but, by default, uses the same
# password string as the stock nextcloud role (POSTGRES_PASSWORD) - no separate
# n8n password is required. Override by setting N8N_DB_PASSWORD if you want a
# distinct credential.
#
# n8n then connects with (see the n8n service in compose.n8n.yaml):
#   DB_POSTGRESDB_HOST=postgres-db
#   DB_POSTGRESDB_DATABASE=$N8N_DB_NAME      (default n8n)
#   DB_POSTGRESDB_USER=$N8N_DB_USER          (default n8n)
#   DB_POSTGRESDB_PASSWORD=$N8N_DB_PASSWORD  (default = POSTGRES_PASSWORD)
set -euo pipefail

: "${N8N_DB_NAME:-n8n}"
: "${N8N_DB_USER:-n8n}"
# Default: reuse the stock Postgres password (separate role, same credential).
: "${N8N_DB_PASSWORD:-$POSTGRES_PASSWORD}"

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