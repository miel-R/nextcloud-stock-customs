# Installation guide

This guide covers deploying the `compose.yaml` stack from scratch on a single Docker host.
It assumes a Linux host (or Windows with Docker Desktop) with Docker Engine + Compose v2 and, optionally, Tailscale for the Funnel setup.

## 0. Sizing the host (~400 users)

| Component | RAM reserved | Notes |
| --- | --- | --- |
| nextcloud-db | 2-4 GB | `shared_buffers=1G`, `max_connections=150` |
| nextcloud-redis | 0.5-1 GB | sessions, cache, file locking |
| nextcloud-app | 2-8 GB per replica | `MaxRequestWorkers=60` needs ~8G per replica |
| nextcloud-cron | 1-2 GB | background jobs |
| caddy | 0.25-0.5 GB | static + reverse proxy |
| OS + Docker + headroom | 4-8 GB | journal, images, page cache |

Total: **32 GB RAM** and **4+ vCPU** is the comfortable starting point for 400 users on one host; go to 64 GB if you plan heavy Talk usage or 2 app replicas. Backups need extra disk (see [BACKUP.md](BACKUP.md)).

PostgreSQL and Redis are deployed from the separate `compose.db.yaml` project (they must be reachable from the app containers over `nextcloud-network`); they still count towards the same host sizing.

## 1. Network (one-time)

The compose file uses an *external* network named `nextcloud-network`:

```bash
docker network create nextcloud-network
```

If it does not exist, `docker compose up` will fail with "network nextcloud-network not found".

## 2. Environment file

```bash
cp .env.example .env
```

Fill in at minimum:

```bash
POSTGRES_PASSWORD=<long random>          # openssl rand -base64 24
NEXTCLOUD_ADMIN_PASSWORD=<long random>
NC_DOMAIN=nextcloud.example.com          # no scheme, no port
OVERWRITECLIURL=https://nextcloud.example.com
OVERWRITEPROTOCOL=https
NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1 nextcloud nextcloud.example.com
TRUSTED_PROXIES=<subnet of the docker network>   # docker network inspect nextcloud-network
```

If you use a **Tailscale Funnel** for a `.ts.net` domain and no real certificate, use:

```bash
OVERWRITECLIURL=https://<your>.ts.net
OVERWRITEPROTOCOL=https
```

`.env` is gitignored. Never commit it. Secrets are only read on first boot (install), so changing them later requires occ or a fresh install.

## 3. DNS / TLS (pick one)

**A) Tailscale Funnel (no public IP / CGNAT)** - Tailscale terminates TLS, forwards HTTP to Caddy on `:80`:

```bash
tailscale funnel --bg http://127.0.0.1:80
```

**B) Direct Caddy + Let's Encrypt** - add `:443` handling to the Caddyfile and map `NC_DOMAIN` DNS A record to the host, open 80/443.

**C) Cloudflare Tunnel** - `cloudflared tunnel --url http://127.0.0.1:80`, set the public hostname to the Nextcloud host.

## 4. Start

```bash
# 1) stateful services first (separate project: db + redis)
docker compose -f compose.db.yaml up -d

# 2) then the app tier
docker compose up -d
docker compose ps
```

The app container runs the image entrypoint which installs Nextcloud on first boot (admin + database) using the `.env` values. Give it 1-3 minutes; watch with:

```bash
docker compose logs -f nextcloud-app
```

Verify:

```bash
curl -fsS http://localhost/status.php   # {"installed":true,...}
```

## 5. First login

- URL: `https://<NC_DOMAIN>` (or `http://<host>` locally)
- User / password: `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD`

Change/verify from the admin settings: trusted domains (`Settings > Security` or `occ config:system:set trusted_domains ...`), mail, reverse-proxy settings. The image sets `overwritehost`, `overwriteprotocol` and `overwrite.cli.url` from env, so careful manual `occ` changes are usually not required.

## 6. Verify background jobs

Cron runs in the dedicated `nextcloud-cron` container (official `/cron.sh`):

```bash
docker compose logs -f nextcloud-cron
```

In Nextcloud admin: `Basic settings > Background jobs` should show **Cron** as last job run "now".

## 7. Optional: extra app replica

```bash
docker compose up -d --scale nextcloud-app=2
```

See [SCALING.md](SCALING.md) for the full story.

## 8. Optional: Talk

Follow the Talk section of the [README](readme.md). It needs the signaling backend reachable over `https://<NC_DOMAIN>` and UDP/TCP 3478 open.

## 9. Backups

Set up the daily backup described in [BACKUP.md](BACKUP.md) **before** onboarding users.

## 10. Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `network nextcloud-network not found` | Run `docker network create nextcloud-network` |
| 500 on first load | `docker compose logs nextcloud-app`; DB not started yet or `POSTGRES_PASSWORD` empty |
| App can't reach `nextcloud-db` / DB errors at boot | Start the database project first: `docker compose -f compose.db.yaml up -d` |
| "Trusted domain" error | Add the host to `NEXTCLOUD_TRUSTED_DOMAINS` and recreate the app container |
| App container restarts / OOM | Lower `MaxRequestWorkers` in `config/apache-mpm.conf` or raise the memory limit |
| Uploads stuck at 512 MB | Ensure the app runs with the `zz-custom.ini` mount (see compose) and `APACHE_BODY_LIMIT=10G` |
| Sessions lost on scaling | Confirm `REDIS_HOST` is set on the app (image writes PHP session handler to Redis) |