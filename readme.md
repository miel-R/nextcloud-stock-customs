<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# nextcloud-stock-customs

Stock Nextcloud (`nextcloud:stable` + `postgres:16` + `redis` + `caddy`) — **no AIO, no 100-user limit**. Same `nextcloud-aio-*` naming for compatibility.

This repo is the former `nextcloud-aio-customs` converted to stock. Use `compose.yaml` (`nextcloud-aio` network) with `ami-nextcloud-talk` bot.

## Stack

- `nextcloud-aio-database` (postgres:16), `nextcloud-aio-redis` (redis:alpine), `nextcloud-aio-nextcloud` (`nextcloud:stable`), `caddy` (caddy:alpine → `nextcloud-aio-nextcloud:80`)

## Quick start

```bash
cp .env.example .env   # set POSTGRES_PASSWORD, NEXTCLOUD_ADMIN_*, NC_DOMAIN
docker compose up -d
# http://localhost:8080  (caddy also on :80/:443)
```

## Tailscale Funnel (desktop app on ck1189.tail650e17.ts.net)

```powershell
tailscale funnel --bg http://127.0.0.1:80
# → https://ck1189.tail650e17.ts.net (Funnel on)
```

Then fix Nextcloud trusted domains:

```bash
docker exec -u www-data nextcloud-aio-nextcloud php occ config:system:set trusted_domains 5 --value=ck1189.tail650e17.ts.net
docker exec -u www-data nextcloud-aio-nextcloud php occ config:system:set overwritehost --value=ck1189.tail650e17.ts.net
docker exec -u www-data nextcloud-aio-nextcloud php occ config:system:set overwrite.cli.url --value=https://ck1189.tail650e17.ts.net
```

Desktop app → `https://ck1189.tail650e17.ts.net` (`admin` / `NEXTCLOUD_ADMIN_PASSWORD`).

## Ami bot

- `http://ami-talk-bot:3979/api/talk/webhook` on `nextcloud-aio` (`TALK_SERVER_URL=http://nextcloud-aio-nextcloud:80`)
- See [ami-nextcloud-talk](https://github.com/miel-R/ami-nextcloud-talk) — [DEPLOYMENT.md](https://github.com/miel-R/ami-nextcloud-talk/blob/main/DEPLOYMENT.md)
