# Installation guide

This guide deploys the `compose.yaml` stack from scratch on a **single Docker host** -
Ubuntu (Docker Engine) or Windows (Docker Desktop / WSL2). Both tracks are given
side by side so you can follow one to the end.

**Start order is the one thing to get right.** The stack splits into two Compose
projects, and they must come up in this order:

1. the **shared network** (one-time) - `nextcloud-network`
2. the **stateful project** - `compose.db.yaml` (PostgreSQL + Redis) - ALWAYS FIRST
3. the **app project** - `compose.yaml` (Nextcloud, cron, Talk signaling/TURN, Caddy)

Caddy is part of the app project (step 3). It reads the `Caddyfile` when it
starts, so finish the **DNS / TLS choice (step 6) before first start**.

---

## 0. Quick orientation

| Project | File | Services | Starts |
| --- | --- | --- | --- |
| `nextcloud-database` | `compose.db.yaml` | `nextcloud-db`, `nextcloud-redis` | **1st (always)** |
| `nextcloud-stack` | `compose.yaml` | `nextcloud-app`, `nextcloud-cron`, `signaling`, `turn`, `caddy` | 2nd |

Both connect over the single external network `nextcloud-network`.

## 1. Sizing the host

Sizing is **env-driven** - there are no hardcoded memory/CPU values in the
compose files. All limits read from **`.env`** (see [SCALING.md](SCALING.md)).

Two ready-made presets are shipped in `.env.example`:

- **Preset A (default): small host** - 8 GB RAM, Talk kept at full size,
  `APP_REPLICAS=1` (the minimum). Good for ~25-75 light users.
- **Preset B (uncomment): standard host** - 32-64 GB RAM, up to ~400 users,
  2 replicas possible.

| Host RAM | Preset | Realistic load |
| --- | --- | --- |
| 8 GB | A | 25-75 light users with Talk |
| 16 GB | A (raise `APP_MEM_LIMIT`/`APP_MAX_WORKERS`) | 75-150 |
| 32+ GB | B | 150-400 |

## 2. Prerequisites (Docker itself)

**Ubuntu (Docker Engine + Compose plugin):**

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

Log out and back in (so the `docker` group applies), then verify:

```bash
docker --version
docker compose version
```

**Windows (Docker Desktop, WSL2 backend):**

```powershell
winget install Docker.DockerDesktop
```

Start Docker Desktop once, accept the WSL2 backend, and sign out/in so `docker`
is on your PATH. Verify:

```powershell
docker --version
docker compose version
dmesg --not-supported  # Windows has no dmesg; skip the OOM checks from SCALING.md
```

> Note: on Windows, the Linux `user: "9000:9000"` in the `turn` service works
> because Docker Desktop runs Linux containers under WSL2.

## 3. Get the code

**Ubuntu:**

```bash
git clone <your-repo-url> nextcloud-stock-customs
cd nextcloud-stock-customs
```

**Windows (PowerShell):**

```powershell
git clone <your-repo-url> nextcloud-stock-customs
Set-Location nextcloud-stock-customs
```

## 4. One-time network

Both projects expect an **external** network named `nextcloud-network`. Create it
once (any OS):

```bash
docker network create nextcloud-network
```

If you ever see `network nextcloud-network not found`, re-run this exact command.

## 5. Environment file

Create `.env` from the template:

```bash
# Ubuntu
cp .env.example .env
nano .env
```

```powershell
# Windows
Copy-Item .env.example .env
notepad .env
```

Fill in at the minimum the secrets and domain (`openssl rand -base64 24` to
generate passwords; on Windows use `docker run --rm alpine openssl rand -base64 24`):

```bash
POSTGRES_PASSWORD=<long random>
NEXTCLOUD_ADMIN_PASSWORD=<long random>
NC_DOMAIN=nextcloud.example.com          # no scheme, no port
OVERWRITECLIURL=https://nextcloud.example.com
OVERWRITEPROTOCOL=https
NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1 nextcloud nextcloud.example.com
TRUSTED_PROXIES=<subnet>                 # docker network inspect nextcloud-network
```

If using **Tailscale Funnel** (`.ts.net` domain, no real certificate):

```bash
OVERWRITECLIURL=https://<your>.ts.net
OVERWRITEPROTOCOL=https
```

Leave the **SIZING block** on Preset A (default) for an 8 GB box, or uncomment
Preset B for a 32+ GB host. `.env` is gitignored - never commit it. Secrets are
only read on first boot, so changing them later needs `occ` or a fresh install.

## 6. DNS / TLS - choose ONE before first start (Caddy needs it at boot)

**A) Tailscale Funnel (no public IP / CGNAT)** - Tailscale terminates TLS and
forwards HTTP to Caddy on `:80`:

```bash
tailscale funnel --bg http://127.0.0.1:80
```

**B) Direct Caddy + Let's Encrypt** - point an A record for `NC_DOMAIN` at this
host, open ports 80/443, and add a `:443` site block to `Caddyfile`.

**C) Cloudflare Tunnel** - run `cloudflared tunnel --url http://127.0.0.1:80`
and set the public hostname to the Nextcloud host.

## 7. Start - database first, then the app tier

> **Order matters.** `nextcloud-app` crash-loops until the DB answers, so the
> stateful project always goes up first. Identical commands on both OS.

```bash
# 1) stateful first (separate project: PostgreSQL + Redis)
docker compose -f compose.db.yaml up -d

# 2) then the whole app tier incl. Caddy, cron, Talk, Nextcloud
docker compose up -d --remove-orphans

# status
docker compose ps
```

The app container runs the image entrypoint, which installs Nextcloud on first
boot (admin user + database from `.env`). Give it 1-3 minutes and watch:

```bash
docker compose logs -f nextcloud-app
```

Verify the install (Ubuntu):

```bash
curl -fsS http://localhost/status.php   # {"installed":true,...}
```

Windows (PowerShell): `curl.exe` is the real curl, `curl` would be an alias:

```powershell
curl.exe -fsS http://localhost/status.php
```

## 8. First login

- URL: `https://<NC_DOMAIN>` (or `http://<host>:80` locally)
- User / password: `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD`

The image sets `overwritehost`, `overwriteprotocol` and `overwrite.cli.url` from
the `.env` values, so manual `occ` changes are usually not required.

## 9. Verify background jobs

Cron runs in the dedicated `nextcloud-cron` container:

```bash
docker compose logs -f nextcloud-cron
```

In Nextcloud: `Administration settings > Basic settings > Background jobs`
should show **Cron** running "now".

## 10. Optional: Talk

`signaling` and `turn` are already in `compose.yaml` and start with the stack.
They need the signaling backend reachable at `https://<NC_DOMAIN>` and UDP/TCP
3478 open to clients. Complete the wiring from the [README Talk section](readme.md):

```bash
docker exec -u www-data nextcloud-app php occ spreed:signaling:add <NC_DOMAIN> --secret=<SIGNALING_SECRET> --verify=1
docker exec -u www-data nextcloud-app php occ spreed:turn:add udp <NC_DOMAIN>:3478 --secret=<TURN_SECRET>
docker exec -u www-data nextcloud-app php occ spreed:turn:add tcp <NC_DOMAIN>:3478 --secret=<TURN_SECRET>
```

## 11. Optional: extra app replica

`APP_REPLICAS` defaults to **1** (the minimum). Add replicas only when the host
has the RAM and metrics justify it (see [SCALING.md](SCALING.md) - on <= 16 GB
hosts keep 1 replica):

```bash
docker compose up -d --scale nextcloud-app=2
```

## 12. Backups

Set up the daily backup described in [BACKUP.md](BACKUP.md) **before** onboarding users.

## 13. Everyday operations

Stop (app tier first, then the database):

```bash
docker compose down          # app tier
docker compose -f compose.db.yaml down   # then stateful
```

Change sizing in `.env`? Just bring the stack back up - Compose recreates the
containers with the new limits:

```bash
docker compose -f compose.db.yaml up -d   # DB + Redis first
docker compose up -d --remove-orphans
```

Full reinstall / fresh start uses the same two commands plus the one-time
`docker network create nextcloud-network`.

## 14. Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `network nextcloud-network not found` | Run `docker network create nextcloud-network` once |
| 500 on first load | `docker compose logs nextcloud-app`; DB not started yet or `POSTGRES_PASSWORD` empty - start `compose.db.yaml` first |
| App can't reach `nextcloud-db` / DB errors at boot | Start the database project first: `docker compose -f compose.db.yaml up -d` |
| "Trusted domain" error | Add the host to `NEXTCLOUD_TRUSTED_DOMAINS` and recreate the app container |
| App container restarts / OOM | Lower `APP_MAX_WORKERS` and/or `APP_MEM_LIMIT` in `.env` (they must stay in ratio: workers x ~150 MB < limit), or raise the host RAM |
| Talk no audio / no signaling | Verify `spreed:signaling:list` / `spreed:turn:list`; 3478 UDP/TCP reachable; host RAM (see small-host profile in [SCALING.md](SCALING.md)) |
| Host OOM-kills containers despite limits | Add swap (`fallocate -l 8G /swapfile` on Ubuntu); aux services carry `oom_score_adj: 500` so the app/Talk tier dies last |
| Uploads stuck at 512 MB | Keep `upload_max_filesize`/`post_max_size` in `config/php-custom.ini` in sync with `UPLOAD_MAX_SIZE` in `.env` (both default `2G`) and recreate the app container |
| Sessions lost on scaling | Confirm `REDIS_HOST` is set on the app (image writes the PHP session handler to Redis) |