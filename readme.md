<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# nextcloud-stock-customs

A stock Nextcloud Docker stack sized for ~400 users: `nextcloud:stable` (Apache + PHP) behind a Caddy reverse proxy, with PostgreSQL 16, Redis (sessions/cache/locking), a dedicated cron container and optional Nextcloud Talk.

No AIO mastercontainer, no 100-user limit - you own the scaling and the upgrades.

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
| `nextcloud-app` | `nextcloud:stable` | Nextcloud Apache + PHP (scalable, no host ports) |
| `nextcloud-cron` | `nextcloud:stable` | Background jobs via the official `/cron.sh` |
| `talk` | `nextcloud/aio-talk:latest` | Optional Talk signaling + TURN (needs www + secrets) |
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

Talk secrets: `openssl rand -base64 32`.

## Configuration

| File | What it tunes |
| --- | --- |
| `.env` | Passwords, domain, trusted proxies, Talk secrets (gitignored) |
| `config/php-custom.ini` | Mounted as `zz-custom.ini` so it overrides the image defaults (10G uploads, 512M opcache, APCu) |
| `config/apache-mpm.conf` | `MaxRequestWorkers=60` sized to the 8G app container (150 would OOM under load) |
| `config/postgres-tuning.conf` | `shared_buffers=1G`, `max_connections=150`, WAL + planner tuning |
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

Docker's embedded DNS round-robins the `nextcloud-app` name, so Caddy balances automatically.
Real elastic autoscaling (adding replicas on load) needs Swarm/Kubernetes - details and trade-offs in SCALING.md.

## Backups

See [BACKUP.md](BACKUP.md). Minimum viable setup on the host (daily cron):

- `pg_dump` the `nextcloud` database to disk
- snapshot/rsync the `nextcloud_www` volume (with `occ maintenance:mode --on` for a consistent copy)

## Talk

`talk` is optional and needs the public domain to serve the signaling backend:

```bash
# app: enable the app
docker exec -u www-data nextcloud-app php occ app:enable spreed

# app: tell Nextcloud where the signaling + TURN servers live
docker exec -u www-data nextcloud-app php occ spreed:signaling:add <NC_DOMAIN> --secret=<SIGNALING_SECRET> --verify=1
docker exec -u www-data nextcloud-app php occ spreed:turn:add udp <NC_DOMAIN>:3478 --secret=<TURN_SECRET>
docker exec -u www-data nextcloud-app php occ spreed:turn:add tcp <NC_DOMAIN>:3478 --secret=<TURN_SECRET>
```

Notes:

- The AIO Talk container's signaling server listens on **8081** internally; the Caddyfile already proxies `/standalone-signaling` there.
- Its signaling backend calls `https://<NC_DOMAIN>`. If you only have HTTP on `:80` (Tailscale Funnel), set `NC_DOMAIN` to a name that resolves publicly to the funnel, or add a TLS listener on `:443` (e.g. `tls internal` in Caddy) and set `SKIP_CERT_VERIFY=true` on the talk container for an internal-only setup.
- Open/forward UDP **and** TCP 3478 on the firewall for TURN.

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
- AIO project: [nextcloud/all-in-one](https://github.com/nextcloud/all-in-one)
- Amiteller Help Desk bot: [ami-nextcloud-talk](https://github.com/miel-R/ami-nextcloud-talk) (optional companion repo)