<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# nextcloud-stock-customs

A stock Nextcloud Docker stack sized for ~400 users: `nextcloud:stable-fpm` (PHP-FPM) fronted by a stock `nginx` sidecar, behind a Caddy reverse proxy, with PostgreSQL 16, Redis (sessions/cache/locking), a dedicated cron container and optional Nextcloud Talk. The app tier uses the AIO-style runtime model (nginx + PHP-FPM) with **stock images only** - no mastercontainer, no 100-user limit: you own the scaling and the upgrades.

## Contents

| Topic | Why |
| --- | --- |
| [Stack](#stack) | What runs and why |
| [Quick start](#quick-start) | Bring the stack up on a fresh host |
| [Configuration](#configuration) | `.env` and `config/` reference |
| [Networking / TLS / domain](#networking--tls--domain) | Reverse proxy options, domain provider, Cloudflare caveats |
| [Database](#database) | Standalone Postgres/Redis project + managed-cloud migration |
| [Scaling](#scaling) | Horizontal app replicas + honest autoscaling notes |
| [Backups](#backups) | DB + file backup / restore |
| [Talk](#talk) | Signaling / TURN wiring (optional) |
| [Upgrading](#upgrading) | Nextcloud + image updates |
| [Monitoring](#monitoring) | Keep an eye on 400 users |

## Stack

| Service | Image | Role |
| --- | --- | --- |
| `nextcloud-db` | `postgres:16-alpine` | Database - standalone project (`compose.db.yaml`) |
| `nextcloud-redis` | `redis:alpine` | PHP sessions, distributed cache, file locking - standalone project |
| `nextcloud-app` | `nextcloud:stable-fpm` | Nextcloud PHP-FPM (scalable, no host ports; pool auto-scales with `APP_MEM_LIMIT`) |
| `nextcloud-nginx` | `nginx:1.27-alpine` | Serves static files + proxies PHP to `nextcloud-app:9000` (AIO-style runtime model) |
| `nextcloud-cron` | `nextcloud:stable` | Background jobs via the official `/cron.sh` |
| `signaling` | `strukturag/nextcloud-spreed-signaling:2.1.1` | Optional Talk standalone signaling server (backend-authorised, no webroot mount) |
| `turn` | `eturnal/eturnal:1.12.2` | Optional STUN/TURN relay for Talk clients behind restrictive NATs |
| `caddy` | `caddy:alpine` | Reverse proxy on `:80` (TLS terminated upstream) |

Everything connects over the external Docker network `nextcloud-network`:

```bash
docker network create nextcloud-network   # one time, before first up
```

Named volumes: `nextcloud_db` (Postgres - owned by the database project), `nextcloud_www` (Nextcloud webroot + data), `caddy_data` / `caddy_config`. The stack is split into two Compose projects - see [Database](#database).

## Quick start

```bash
# 1. External network (one-time)
docker network create nextcloud-network

# 2. Environment
cp .env.example .env
#    edit .env: POSTGRES_PASSWORD, NEXTCLOUD_ADMIN_PASSWORD, NC_DOMAIN,
#    OVERWRITE*, NEXTCLOUD_TRUSTED_DOMAINS, TRUSTED_PROXIES, Talk secrets
#    (TRUSTED_PROXIES must match `docker network inspect nextcloud-network` subnet)

# 3. Start stateful services (PostgreSQL + Redis) - separate project
docker compose -f compose.db.yaml up -d

# 4. Start the app stack
docker compose up -d

# 5. Verify
docker compose ps
docker compose logs -f nextcloud-app
curl -fsS http://localhost/status.php
```

First boot creates the admin account and the database automatically. Log in at `http://<host>` (or your public `NC_DOMAIN`).

Talk secrets: `openssl rand -base64 32` for `TURN_SECRET` / `SIGNALING_SECRET` / `INTERNAL_SECRET`,
`openssl rand -hex 16` for `BLOCK_KEY`, `openssl rand -hex 32` for `HASH_KEY`.

## Configuration

| File | What it tunes |
| --- | --- |
| `.env` | Passwords, domain, trusted proxies, Talk secrets (gitignored) |
| `config/php-custom.ini` | Mounted as `zz-custom.ini` so it overrides the image defaults (2G uploads, 128M opcache, APCu) - keep uploads in sync with `UPLOAD_MAX_SIZE` |
| `config/fpm-entrypoint.sh` | Renders the PHP-FPM pool (`zz-pool.conf`) from env at startup; auto-derives `pm.max_children` from `APP_MEM_LIMIT` at ~150 MB/child unless `APP_FPM_MAX_CHILDREN` is set |
| `config/nginx.conf` | Nginx sidecar config: serves static files from the shared `nextcloud` webroot (incl. `.mjs` with the JS MIME type), proxies PHP to `nextcloud-app:9000`, front-controller routes clean URLs to `index.php`, handles `.well-known`/OCS discovery, sets the admin-recommended security headers, `client_max_body_size` = `UPLOAD_MAX_SIZE` |
| `config/postgres-tuning.conf` | WAL + planner tuning + `listen_addresses='*'` (required so the app can reach Postgres and the image can create the DB); memory knobs live in `.env` (`DB_*`, passed on the DB command line) |
| `config/pg_hba.conf` | Mounted client-auth rules allowing the `nextcloud-network` subnet (stock default only trusts localhost, which would block the app) |
| `Caddyfile` | Route to app + Talk signaling (`:80`, gzip, static caching) |

> The image's `TRUSTED_PROXIES` handling expects a **space-separated** list and `trusted_domains` also accepts spaces - keep that format in `.env`.

## Networking / TLS / domain

How you expose the stack and which domain provider to use is a key decision for
a 400-user rollout. See [NETWORKING.md](NETWORKING.md) for the full comparison:

| Option | Best when |
| --- | --- |
| Caddy :443 + Let's Encrypt | public IP / port-forward available - standard, best uploads |
| Caddy :80 + Tailscale Funnel (current) | CGNAT / no open ports |
| Cloudflare Tunnel -> Caddy | zero open ports + WAF (verify 100MB upload cap) |
| No proxy (Tailscale Serve/Funnel) | private tailnet, or public with no caching needed |

Recommended domain provider: **Cloudflare Registrar + DNS** (often DNS-only /
grey cloud for large uploads). See NETWORKING.md for exact `.env` + `Caddyfile` +
`compose.yaml` changes per option.

## Database (standalone)

PostgreSQL + Redis run in their own Compose project (`compose.db.yaml`) so the
web tier scales freely without ever touching them:

```bash
docker compose -f compose.db.yaml up -d            # stateful services first
docker compose up -d --scale nextcloud-app=2       # web tier scales separately
```

Startup order, backup commands and the migration path to a managed database:
[DATABASE.md](DATABASE.md).

## Scaling

For ~400 users start with `docker compose up -d --scale nextcloud-app=2` (see [SCALING.md](SCALING.md) for sizing).
Because PHP sessions, distributed cache and locking are all in Redis, app instances are stateless:

```bash
docker compose up -d --scale nextcloud-app=3   # scale out
docker compose up -d --scale nextcloud-app=1   # scale back for upgrades
```

Docker's embedded DNS round-robins the `nextcloud-app` name, so nginx balances FPM automatically across replicas. Real elastic autoscaling (adding replicas on load) needs Swarm/Kubernetes - details and trade-offs in SCALING.md.

## Backups

See [BACKUP.md](BACKUP.md). Minimum viable setup on the host (daily cron):

- `pg_dump` the `nextcloud` database to disk
- snapshot/rsync the `nextcloud_www` volume (with `occ maintenance:mode --on` for a consistent copy)

## Talk

`signaling` and `turn` are optional and need the public domain to serve the signaling backend:

```bash
# app: enable the app
docker exec -u www-data nextcloud-app php occ app:enable spreed

# app: tell Nextcloud where the signaling (HPB) + TURN servers live (NC 34+ uses
# the talk: namespace; the old spreed: commands were renamed)
docker exec -u www-data nextcloud-app php occ talk:signaling:add "wss://<NC_DOMAIN>/standalone-signaling" <SIGNALING_SECRET> --verify
docker exec -u www-data nextcloud-app php occ talk:turn:add turn <NC_DOMAIN> udp,tcp --secret=<TURN_SECRET>
```

Notes:

- The `signaling` container (spreed standalone signaling server) listens on **8081** internally; the Caddyfile already proxies `/standalone-signaling` there.
- The signaling server authenticates through the Nextcloud backend (`BACKEND_BACKEND1_URLS=https://<NC_DOMAIN>` in `compose.yaml`). If you only have HTTP on `:80` (Tailscale Funnel), set `NC_DOMAIN` to a name that resolves publicly to the funnel, or add a TLS listener on `:443` (e.g. `tls internal` in Caddy) and set `SKIP_VERIFY=true` on the signaling service for an internal-only setup.
- Open/forward UDP **and** TCP 3478 on the firewall for TURN. The 16k relay range is **not** published by default (it lags startup); if your clients need a real relay, apply the optional `compose.turn.yaml` override on native Linux and forward the small relay range it publishes (see `INSTALL.md`).
- If the `turn` service auto-detects the wrong relay address, force it by adding `ETURNAL_RELAY_IPV4_ADDR: ${TURN_RELAY_IP:-}` to its environment in `compose.yaml` and setting `TURN_RELAY_IP=<public-ip>` in `.env`.

## Upgrading

```bash
# Put Nextcloud into maintenance mode
docker exec -u www-data nextcloud-app php occ maintenance:mode --on

# Pull new images and recreate (scale app back to 1 first if you scaled out)
docker compose pull
docker compose up -d --remove-orphans

# Finish the upgrade (the app entrypoint runs `occ upgrade` automatically, but be explicit)
docker exec -u www-data nextcloud-app php occ upgrade
docker exec -u www-data nextcloud-app php occ maintenance:mode --off
```

## Monitoring

- Health checks: `docker compose ps` (app tier) and `docker compose -f compose.db.yaml ps` (db + redis).
- `http://<host>/status.php` returns the instance health.
- Enable the **Serverinfo** app in Nextcloud and install the Nextcloud Serverinfo monitoring templates (Percona) or scrape `/ocs/v2.php/apps/serverinfo/api/v1/info` for load, memory and user counts.
- Watch volume usage: `docker system df` and `df -h` on the volume backing directory.

## Related

- Upstream image: [nextcloud docker](https://hub.docker.com/_/nextcloud)
- Talk standalone signaling server: [nextcloud-spreed-signaling](https://github.com/strukturag/nextcloud-spreed-signaling)
- STUN/TURN server: [eturnal](https://github.com/processone/eturnal)
- Amiteller Help Desk bot: [ami-nextcloud-talk](https://github.com/miel-R/ami-nextcloud-talk) (optional companion repo)