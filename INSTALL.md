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

Fill in at the minimum the secrets and domain. To generate passwords on Ubuntu
use `openssl rand -base64 24`; on Windows use the PowerShell one-liner in the
Talk secrets block below (the same `New-Object ... RNGCryptoServiceProvider`
pattern):

```bash
POSTGRES_PASSWORD=<long random>
NEXTCLOUD_ADMIN_PASSWORD=<long random>
NC_DOMAIN=nextcloud.example.com          # no scheme, no port, NO trailing slash
OVERWRITECLIURL=https://nextcloud.example.com
OVERWRITEPROTOCOL=https
NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1 nextcloud nextcloud.example.com
TRUSTED_PROXIES=<subnet>                 # docker network inspect nextcloud-network
```

> **The `nextcloud.example.com` placeholder must be REPLACED by your real domain
> in *all three* places** above: `NC_DOMAIN`, `OVERWRITECLIURL`, and
> `NEXTCLOUD_TRUSTED_DOMAINS`. If you leave the placeholder, or make a typo, the
> browser will show **"Please contact your administrator ... edit the
> trusted_domains setting"** even though the install succeeded.
>
> `NC_DOMAIN` must have **no scheme (no `https://`) and no trailing slash** - a
> trailing `/` breaks the value. The trusted-domain / overwrite settings are read
> when the app container starts, so after changing them you must recreate the app
> container (step 7) - they are **not** picked up from a running container.

If using **Tailscale Funnel** (`.ts.net` domain, no real certificate):

```bash
NC_DOMAIN=<your-host>.ts.net
OVERWRITECLIURL=https://<your-host>.ts.net
OVERWRITEPROTOCOL=https
NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1 nextcloud <your-host>.ts.net
```

### Talk secrets (required - the stack ships Talk)

`signaling` and `turn` fail to start if the Talk secrets are still the
`CHANGE_ME_*` placeholders, so generate real values **before** first start.

**Ubuntu (use `openssl`):**

```bash
openssl rand -base64 32   # run 3x -> TURN_SECRET, SIGNALING_SECRET, INTERNAL_SECRET
openssl rand -hex 16      # BLOCK_KEY
openssl rand -hex 32      # HASH_KEY
```

**Windows (native PowerShell - no Docker/openssl needed):** run these one-liners
3x for the secrets, 1x each for the keys:

```powershell
$rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider; $b = New-Object byte[] 24; $rng.GetBytes($b); [System.Convert]::ToBase64String($b)   # 3x -> TURN, SIGNALING, INTERNAL
$rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider; $b = New-Object byte[] 16; $rng.GetBytes($b); ($b | ForEach-Object { $_.ToString('x2') }) -join ''   # BLOCK_KEY
$rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider; $b = New-Object byte[] 32; $rng.GetBytes($b); ($b | ForEach-Object { $_.ToString('x2') }) -join ''   # HASH_KEY
```

Then paste them into `.env`:

```bash
TURN_SECRET=<base64>
SIGNALING_SECRET=<base64>
INTERNAL_SECRET=<base64>
BLOCK_KEY=<32 hex chars>
HASH_KEY=<64 hex chars>
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

> If you get the **"trusted domain"** page here, the install worked but your
> domain was left out (see step 5). Fix `.env` (`NEXTCLOUD_TRUSTED_DOMAINS`,
> `NC_DOMAIN`) and recreate the app container - you do **not** need to reinstall.
> The recreated entrypoint rewrites `config.php` with the corrected domains.

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
3478 open to clients. If your clients need a real TURN **relay** (restrictive
NAT), also apply the optional override on a native Linux host:
`docker compose -f compose.yaml -f compose.turn.yaml up -d`.
Complete the wiring from the [README Talk section](readme.md):

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
| "Please contact your administrator ... edit the trusted_domains setting" | The real domain is missing from `NEXTCLOUD_TRUSTED_DOMAINS` in `.env` (install succeeded but the browser host isn't trusted). Put your actual domain in as the last entry (`localhost 127.0.0.1 nextcloud <your-domain>`), fix `NC_DOMAIN` (no trailing slash), then recreate the app container so the entrypoint regenerates `config.php` |
| App container restarts / OOM | Lower `APP_MAX_WORKERS` and/or `APP_MEM_LIMIT` in `.env` (they must stay in ratio: workers x ~150 MB < limit), or raise the host RAM |
| `nextcloud-turn` never starts / machine lags on `up` | The 16k UDP relay range (`49152-65535`) is no longer in the main compose file - it hangs on Docker Desktop and is slow on Linux. Use the small optional override only on native Linux when you need TURN relay: `docker compose -f compose.yaml -f compose.turn.yaml up -d` |
| Talk no audio / no signaling | Verify `spreed:signaling:list` / `spreed:turn:list`; 3478 UDP/TCP reachable; host RAM (see small-host profile in [SCALING.md](SCALING.md)) |
| Host OOM-kills containers despite limits | Add swap (`fallocate -l 8G /swapfile` on Ubuntu); aux services carry `oom_score_adj: 500` so the app/Talk tier dies last |
| Uploads stuck at 512 MB | Keep `upload_max_filesize`/`post_max_size` in `config/php-custom.ini` in sync with `UPLOAD_MAX_SIZE` in `.env` (both default `2G`) and set `APACHE_BODY_LIMIT` (bytes) >= it, then recreate the app container |
| Sessions lost on scaling | Confirm `REDIS_HOST` is set on the app (image writes the PHP session handler to Redis) |