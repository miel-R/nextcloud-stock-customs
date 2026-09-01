<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# nextcloud-stock-customs

Stock Nextcloud (`nextcloud:stable` + `postgres:16` + `redis`) — **no AIO, no 100-user limit**.

This repo is the former `nextcloud-aio-customs` converted to stock. Use `compose.yaml` (`nextcloud-net` network) with `ami-nextcloud-talk` bot.

## Quick start

```bash
cp .env.example .env   # set POSTGRES_PASSWORD, NEXTCLOUD_ADMIN_*, NC_DOMAIN
docker compose up -d
# http://localhost:8080
```

Bot: `http://ami-talk-bot:3979/api/talk/webhook` on `nextcloud-net` (`TALK_SERVER_URL=http://nextcloud:80` or your public https).

See [ami-nextcloud-talk](https://github.com/miel-R/ami-nextcloud-talk) — [DEPLOYMENT.md](https://github.com/miel-R/ami-nextcloud-talk/blob/main/DEPLOYMENT.md) for bot setup.
