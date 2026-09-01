<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# nextcloud-stock-customs

Stock Nextcloud (`nextcloud:stable` + `postgres:16` + `redis` + `caddy`) — **no AIO, no 100-user limit**. Same `nextcloud-aio-*` naming for compatibility.

This repo is the former `nextcloud-aio-customs` converted to stock. Use `compose.yaml` (`nextcloud-aio` network) with [`ami-nextcloud-talk`](https://github.com/miel-R/ami-nextcloud-talk) bot.

## Contents

| Topic | Why |
|---|---|
| [Stack](#stack) | What runs |
| [Quick start](#quick-start) | Bring up stock Nextcloud |
| [Caddy (separate Apache)](#caddy-separate-apache) | Like AIO's split `apache` + `app` |
| [Tailscale Funnel](#tailscale-funnel) | Public `https://ck1189.tail650e17.ts.net` for desktop/mobile (no open ports) |
| [Ami bot](#ami-bot) | Webhook `http://ami-talk-bot:3979/api/talk/webhook` on `nextcloud-aio` |
| [Changing domain](#changing-domain) | What to change when you move domains |
| [Bot operations](#bot-operations) | Approve rooms, escalation sink |

## Stack

- `nextcloud-aio-database` (`postgres:16-alpine`)
- `nextcloud-aio-redis` (`redis:alpine`)
- `nextcloud-aio-nextcloud` (`nextcloud:stable` — Apache+PHP bundled, but run as separate `fpm`+`caddy` for AIO-like split)
- `caddy` (`caddy:alpine` → `nextcloud-aio-nextcloud:80`, `80:80` + `443:443`)

All on `nextcloud-aio` (`external: true`, `name: nextcloud-aio`). Volumes `db` + `nextcloud` + `caddy_*`.

## Quick start

```bash
cp .env.example .env   # set POSTGRES_PASSWORD, NEXTCLOUD_ADMIN_*, NC_DOMAIN
# .env example:
# POSTGRES_PASSWORD=...
# NEXTCLOUD_ADMIN_USER=admin
# NEXTCLOUD_ADMIN_PASSWORD=...
# NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1 nextcloud ck1189.tail650e17.ts.net
# OVERWRITECLIURL=https://ck1189.tail650e17.ts.net
# NC_DOMAIN=ck1189.tail650e17.ts.net
docker compose up -d
# http://localhost:8080 (caddy also on :80/:443)
# logs: docker logs nextcloud-aio-nextcloud --tail 20
```

First run creates admin and DB. `caddy` is optional — you can also hit `nextcloud-aio-nextcloud:80` directly via Tailscale.

## Caddy (separate Apache)

Like AIO's `nextcloud-aio-apache` + `nextcloud-aio-nextcloud` split:

- Stock `nextcloud:stable` bundles Apache, but we run `caddy` in front for TLS termination and to keep the web layer separate (mirrors AIO).
- `Caddyfile` → `reverse_proxy nextcloud-aio-nextcloud:80`
- To go fully single-container, just `docker compose stop caddy` and use `nextcloud-aio-nextcloud:80` directly (bot already does `TALK_SERVER_URL=http://nextcloud-aio-nextcloud:80` internally).

## Tailscale Funnel

Publishes stock Nextcloud at `https://ck1189.tail650e17.ts.net` (no open ports, MagicDNS):

```powershell
tailscale funnel --bg http://127.0.0.1:80   # caddy
# or http://127.0.0.1:8080 for direct nextcloud
# → https://ck1189.tail650e17.ts.net (Funnel on)
```

Fix Nextcloud's trusted domains (required for login via the funnel):

```bash
docker exec -u www-data nextcloud-aio-nextcloud php occ config:system:set trusted_domains 5 --value=ck1189.tail650e17.ts.net
docker exec -u www-data nextcloud-aio-nextcloud php occ config:system:set overwritehost --value=ck1189.tail650e17.ts.net
docker exec -u www-data nextcloud-aio-nextcloud php occ config:system:set overwrite.cli.url --value=https://ck1189.tail650e17.ts.net
docker exec -u www-data nextcloud-aio-nextcloud php occ config:system:set overwriteprotocol --value=https
```

Desktop/mobile app → `https://ck1189.tail650e17.ts.net` (`admin` / `NEXTCLOUD_ADMIN_PASSWORD`). No Tailscale needed on the client if you use Cloudflare Tunnel; with Funnel the client must be on the tailnet or the funnel must be public (as above).

## Ami bot

- Webhook: `http://ami-talk-bot:3979/api/talk/webhook` on `nextcloud-aio` (same network, no public port)
- Bot → Nextcloud: `http://nextcloud-aio-nextcloud:80` (`TALK_SERVER_URL`, container-to-container, no TLS)
- See [ami-nextcloud-talk](https://github.com/miel-R/ami-nextcloud-talk) — [DEPLOYMENT.md](https://github.com/miel-R/ami-nextcloud-talk/blob/main/DEPLOYMENT.md) for `talk:bot:install` (`--feature webhook --feature response`, 40-char secret) and per-room enable (`POST /ocs/v2.php/apps/spreed/api/v1/bot/{token}/{id}`).

Compose for the bot (`ami-nextcloud-talk/docker-compose.yml`):

```yaml
services:
  ami-talk-bot:
    build: .
    container_name: ami-talk-bot
    restart: unless-stopped
    networks: [nextcloud-aio]
    env_file: env/.env.dev.user
networks: { nextcloud-aio: { external: true } }
```

## Changing domain

Stock Nextcloud stores the domain in `overwritehost`/`overwrite.cli.url` and `trusted_domains` — not in `NC_DOMAIN` like AIO. To change:

```bash
# 1. Update .env: NEXTCLOUD_TRUSTED_DOMAINS, OVERWRITECLIURL, NC_DOMAIN
# 2. docker compose up -d --force-recreate nextcloud-aio-nextcloud
# 3. occ set (as above) for the new host, or let the env vars apply on recreate
# 4. Bot: edit env/.env.dev.user TALK_SERVER_URL to new https://... and docker compose up -d --build
```

No `talk:bot:install` reinstall needed if the bot stays on the same host/network — webhook URL `http://ami-talk-bot:3979/...` is internal.

## Bot operations

Same as before — see stock `README` in `ami-nextcloud-talk`:

- Approve: `ami $approve` / `ami $revoke` / `ami $list` (admin)
- Escalation sink: `ami $notify-add` (in the target group) / `$notify-remove` / `$notify-list` / `$notify-test`
- Intake: `Department → Category → System → Problem` from `ticket-categories.json`

## Related

- 🤖 [`ami-nextcloud-talk`](https://github.com/miel-R/ami-nextcloud-talk) — Ami Help Desk bot
- ☁️ Upstream: [`nextcloud:stable`](https://hub.docker.com/_/nextcloud)
