<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Standalone database and Redis project

PostgreSQL and Redis run as their own Compose project (`compose.db.yaml`, project
name `nextcloud-database`) so the web tier can scale up and down freely.

## Why this layout

- App replicas all connect to ONE shared database - they never have their own.
  Scaling down therefore never needs to "merge" anything: there was always a
  single Postgres, shared by every replica.
- `docker compose up -d --scale nextcloud-app=3` can never create a second
  Postgres, and `docker compose down` on the app stack never stops the database.
- Backups and upgrades of the stateful tier are isolated from the web tier.

## Layout

| Project | File | Project name | Services | Owns volume |
| --- | --- | --- | --- | --- |
| Database | `compose.db.yaml` | `nextcloud-database` | `nextcloud-db`, `nextcloud-redis` | `nextcloud_db` |
| Web tier | `compose.yaml` | `nextcloud-stack` | `nextcloud-app`, `nextcloud-cron`, `signaling`, `turn`, `caddy` | `nextcloud_www`, `caddy_*` |

Both projects join the same external network `nextcloud-network`; the app
reaches the database via `POSTGRES_HOST=nextcloud-db` and Redis via
`REDIS_HOST=nextcloud-redis` (Docker DNS resolves the service names).

## Start / stop / order

```bash
# stateful services first, then the app tier
docker compose -f compose.db.yaml up -d
docker compose up -d

# scale the app tier whenever you like - the database is untouched
docker compose up -d --scale nextcloud-app=2

# stop in reverse order
docker compose down
docker compose -f compose.db.yaml down
```

The app entrypoint retries the database for ~100s on first boot, so starting
both at once usually works - but the documented order is safer.

## Migrating from the old single-file layout

If you previously ran a single `compose.yaml` that contained `nextcloud-db` in
the same project:

```bash
# 1. stop the old app stack (this also stops its db/redis containers; data is safe)
docker-compose down   # or: docker compose down

# 2. start the new standalone stateful project (reuses the same volume `nextcloud_db`)
docker compose -f compose.db.yaml up -d

# 3. start the new app stack
docker compose up -d
```

The named volume `nextcloud_db` is reused as-is, so existing data stays intact.

## Rules

- Never run `--scale nextcloud-db` or `--scale nextcloud-redis`. They are
  stateful singletons: two PostgreSQL instances on one volume corrupt data, two
  Redis instances fight over sessions, and scaling cannot "merge" them back.
- Postgres sizing is env-driven (`DB_MEM_LIMIT`, `DB_SHARED_BUFFERS`,
  `DB_MAX_CONNECTIONS`, ... in `.env`, see [SCALING.md](SCALING.md)). Small-host
  default: `DB_MEM_LIMIT=2G`, `shared_buffers=512M`, `max_connections=60`;
  standard preset: `4G`, `1G`, `150`. Real DB HA means either a managed database
  (below) or Postgres streaming replication - not needed at this size.

## Backups

- Database: `docker exec nextcloud-db pg_dump -U nextcloud -d nextcloud -Fc`
  (or `docker compose -f compose.db.yaml exec nextcloud-db pg_dump ...`).
  Full procedure in [BACKUP.md](BACKUP.md).
- Files: unchanged, wherever the web tier runs (volume `nextcloud_www`).

## Moving to a managed / cloud database (later)

When you outgrow the single host or want HA + zero-maintenance patching:

1. Provision managed PostgreSQL (DigitalOcean Managed Postgres, AWS RDS, Neon,
   Supabase) with a database named `nextcloud`, a user and a password. Note
   host:port.
2. Allow the app host IP (or private network) in the provider firewall.
3. Export the local data:
   ```bash
   docker exec nextcloud-db pg_dump -U nextcloud -d nextcloud -Fc > pre-migration.dump
   ```
4. Restore into the managed instance (dump is piped via stdin):
   ```bash
   cat pre-migration.dump | docker run --rm -i postgres:16-alpine \
     pg_restore -h <HOST> -p <PORT> -U <USER> -d nextcloud --clean --if-exists
   ```
5. Put Nextcloud in maintenance mode:
   ```bash
   docker exec -u www-data nextcloud-app php occ maintenance:mode --on
   ```
6. Update `.env` (`POSTGRES_HOST` to the managed host, and the password), then
   recreate the app tier so it picks up the new settings:
   ```bash
   docker compose up -d --force-recreate nextcloud-app nextcloud-cron
   ```
7. Managed providers usually enforce TLS. libpq negotiates it automatically
   when the server requires it, so this normally just works. If your provider
   insists on explicit `sslmode=require`, add to `config.php`:
   ```php
   'dbdriveroptions' => [\PDO::PGSQL_ATTR_SSLMODE => 'require'],
   ```
   (`PDO::PGSQL_ATTR_SSLMODE` is available in the PHP 8.4 image shipped by
   `nextcloud:stable`.)
8. Verify `occ status`, log in, browse files, then disable maintenance mode.
9. If everything looks good, stop the local database (keep the volume around as
   a fallback):
   ```bash
   docker compose -f compose.db.yaml stop nextcloud-db
   ```

Rollback: point `.env` back at `POSTGRES_HOST=nextcloud-db`, recreate the app
containers, and the local volume is used again.

## Notes

- Redis can stay local even after the database moves to the cloud - it only
  holds sessions/cache. Move to a managed Redis later only if you need
  multi-node HA.
