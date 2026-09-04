#!/bin/bash
# First-boot provisioning for the shared Postgres instance. Runs only ONCE,
# on the first initialization of the db-services volume (postgres runs
# /docker-entrypoint-initdb.d/*.sh exactly once on an empty data dir).
#
# Creates:
#   1. The n8n role + database (see compose.n8n.yaml for connection details).
#   2. The Nextcloud runtime role "oc_<NEXTCLOUD_ADMIN_USER>" (NC 31+ stores
#      this in config.php as dbuser; the stock image's own entrypoint tries to
#      create it, but only during an empty-volume init that may race with
#      this script). Creating it here as the superuser guarantees it exists
#      before the Nextcloud entrypoint runs.
#
# Both roles are created as SEPARATE login roles. The n8n role reuses
# POSTGRES_PASSWORD by default; the NC runtime role uses NEXTCLOUD_ADMIN_PASSWORD.
set -euo pipefail

# --- n8n role + database ---
: "${N8N_DB_NAME:-n8n}"
: "${N8N_DB_USER:-n8n}"
: "${N8N_DB_PASSWORD:-$POSTGRES_PASSWORD}"

if ! psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -tAc "SELECT 1 FROM pg_roles WHERE rolname='$N8N_DB_USER'" | grep -q 1; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -c "CREATE ROLE \"$N8N_DB_USER\" LOGIN PASSWORD '$N8N_DB_PASSWORD';"
fi

if ! psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -tAc "SELECT 1 FROM pg_database WHERE datname='$N8N_DB_NAME'" | grep -q 1; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -c "CREATE DATABASE \"$N8N_DB_NAME\" OWNER \"$N8N_DB_USER\";"
fi

# --- Nextcloud runtime role (NC 31+ "oc_..." user) ---
: "${NEXTCLOUD_ADMIN_USER:-admin}"
: "${NEXTCLOUD_ADMIN_PASSWORD:?NEXTCLOUD_ADMIN_PASSWORD is required}"
OC_ROLE="oc_${NEXTCLOUD_ADMIN_USER}"

if ! psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -tAc "SELECT 1 FROM pg_roles WHERE rolname='$OC_ROLE'" | grep -q 1; then
    echo "Creating Nextcloud runtime role '$OC_ROLE' ..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -c "CREATE ROLE \"$OC_ROLE\" LOGIN PASSWORD '$NEXTCLOUD_ADMIN_PASSWORD';"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -c "GRANT ALL PRIVILEGES ON DATABASE \"$POSTGRES_DB\" TO \"$OC_ROLE\";"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -c "GRANT ALL PRIVILEGES ON SCHEMA public TO \"$OC_ROLE\";"
fi