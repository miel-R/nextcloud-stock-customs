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
| 16 GB | A (raise `APP_MEM_LIMIT`) | 75-150 |
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
forwards HTTP to Caddy on `:80`. Use this when you are behind CGNAT or can't
port-forward. Requires a Tailscale account (free for personal use).

**A.1 Install Tailscale on Ubuntu:**

```bash
# add the Tailscale apt repo and install
curl -fsSL https://tailscale.com/install.sh | sh

# authenticate this host to your tailnet (opens a browser, or use a pre-auth key)
sudo tailscale up
```

For an unattended install, generate an auth key in the Tailscale admin console
and pass it to `tailscale up --authkey=<KEY>`. The chosen `*.ts.net` hostname is
what you use for `NC_DOMAIN` - check it with:

```bash
tailscale status          # shows your assigned <host>.ts.net name
```

**A.2 Test the funnel before starting Nextcloud** (Caddy will listen on `:80`):

```bash
tailscale funnel --bg http://127.0.0.1:80
```

The browser can now reach the host at `https://<host>.ts.net` while Caddy is on
`:80`. You can also use **Tailscale Serve** for a tailnet-internal-only name
(`tailscale serve --bg http://127.0.0.1:80`) if you do not want a public site.

**A.3 Set `.env` to the HTTPS public URL** (see step 5):

```bash
NC_DOMAIN=<your-host>.ts.net
OVERWRITECLIURL=https://<your-host>.ts.net
OVERWRITEPROTOCOL=https
NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1 nextcloud <your-host>.ts.net
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

## 9. Post-install: clear the admin checks

After first login, the Nextcloud admin page may flag a few default warnings.
Run these once to clear the non-web-server ones (the web-server items - `.mjs`
MIME type, security headers, `.well-known`/OCS routing, PHP memory limit, OPcache
- are already handled by `config/nginx.conf` and `config/php-custom.ini`):

```bash
# maintenance window: heavy daily background jobs at 01:00, off-peak
docker exec -u www-data nextcloud-app php occ config:system:set maintenance_window_start --value=1

# apply pending mimetype migrations (only needed occasionally, on upgrades)
docker exec -u www-data nextcloud-app php occ maintenance:repair --include-expensive
```

> The **High-performance backend** (Talk) warning is resolved separately by
> completing the Talk wiring in step 11 (`talk:signaling:add` + `talk:turn:add`).

## 10. Verify background jobs

Cron runs in the dedicated `nextcloud-cron` container:

```bash
docker compose logs -f nextcloud-cron
```

In Nextcloud: `Administration settings > Basic settings > Background jobs`
should show **Cron** running "now".

## 11. Optional: Talk (High-performance backend + TURN)

This stack ships the **standalone High-performance backend (HPB)** (`signaling`)
and a **STUN/TURN** relay (`turn`) as stock images in `compose.yaml`. They start
with the stack, but until you register them in Nextcloud Talk they complain
(admin warning: *"No High-performance backend configured"*) and calls are capped
at ~2-3 participants. This step completes the wiring.

### 11.1 Prerequisites

- The `signaling` and `turn` containers are up and healthy (`docker compose ps`).
- `NC_DOMAIN`, the Talk secrets (`TURN_SECRET`, `SIGNALING_SECRET`,
  `INTERNAL_SECRET`) and the session keys (`BLOCK_KEY`, `HASH_KEY`) are set in
  `.env` (see step 5). `INTERNAL_SECRET` must equal `SIGNALING_SECRET` for the
  HPB to authenticate with Nextcloud.
- Port **3478** (UDP **and** TCP) is reachable from clients for TURN.
- The Talk app (`spreed`) is enabled:
  ```bash
  docker exec -u www-data nextcloud-app php occ app:enable spreed
  ```

### 11.2 Register the signaling (HPB) server

The signals are exchanged over the public domain. `nextcloud-app` has no fixed
container name (so it can be `--scale`d), so run `occ` via the service name.

```bash
# NC 34+ uses the talk: namespace (the old spreed:* commands were renamed).
# <SIGNALING_SECRET> must equal the SIGNALING_SECRET in .env.
docker exec -u www-data nextcloud-app php occ talk:signaling:add \
  "wss://<NC_DOMAIN>/standalone-signaling" <SIGNALING_SECRET> --verify
```

- The `<server>` argument is the **WebSocket** URL the browser talks to. Over
  Tailscale Funnel / TLS-terminated edge this is `wss://<NC_DOMAIN>/standalone-signaling`
  (the `Caddyfile` already proxies `/standalone-signaling` to the signaling
  container on `:8081`).
- `--verify` validates the SSL certificate (correct for real TLS). For an
  internal-only HTTP setup, set `SKIP_VERIFY=true` on the signaling service and
  omit `--verify`.

Check it registered:

```bash
docker exec -u www-data nextcloud-app php occ talk:signaling:list
```

### 11.3 Register TURN

```bash
# schemes: `turn` (or `turn,turns`); protocols: `udp,tcp`; --secret = TURN_SECRET
docker exec -u www-data nextcloud-app php occ talk:turn:add \
  turn <NC_DOMAIN> udp,tcp --secret=<TURN_SECRET>

docker exec -u www-data nextcloud-app php occ talk:turn:list
```

### 11.4 Verify in Nextcloud

Open **Administration settings > Talk**, or `/index.php/settings/admin/office` ->
**Talk/HPB**. The signaling server should show as **connected**, with the WebSocket
URL and a feature list (audio-video-permissions, chat-relay, dialout, federation,
hello-v2, join-features, switchto, virtual-sessions, ...). That clears the
"High-performance backend" admin warning.

> **Known version notice:** if you see *"Server does not support all features of
> this Talk version, missing features: changed-users"*, it is a **version gap**
> between `strukturag/nextcloud-spreed-signaling:2.1.1` and the Talk version in
> Nextcloud 34, not a misconfiguration. Calls still work; bumping the signaling
> image to a release that implements `changed-users` silences the notice.

## 12. Compose projects & how the deployment is assembled

The stack is deliberately split into **two Compose projects** plus **one optional
override file**. This is the "composite deploy": the stateful tier is kept in its
own project so the web tier can be scaled up/down and upgraded without ever
touching the database, and Talk TURN relay can be turned on with an overlay.

| File | Project | What it runs | When to `up` it |
| --- | --- | --- | --- |
| `compose.db.yaml` | `nextcloud-database` | PostgreSQL (`nextcloud-db`) + Redis (`nextcloud-redis`) — **singletons** | Always first |
| `compose.yaml` | `nextcloud-stack` | `nextcloud-app` (PHP-FPM), `nextcloud-nginx`, `nextcloud-cron`, `signaling`, `turn`, `caddy` | Always second |
| `compose.turn.yaml` (override) | `nextcloud-stack` (merged into `compose.yaml`) | TURN **relay** UDP port range for media | Only on native Linux, only if clients need a real relay |

### 12.1 Two projects, one shared network

Both projects connect over the single external network `nextcloud-network`
(created once, step 4). Containers in either project resolve each other by
service name across the projects to that one network.

Volumes:
- `nextcloud_db` — PostgreSQL data (owned by `compose.db.yaml`)
- `nextcloud_www` — Nextcloud webroot + data (shared read-write by app + cron,
  read-only by nginx)
- `caddy_data` / `caddy_config` — Caddy config/state (owned by `compose.yaml`)

### 12.2 The app tier stacking (nginx + PHP-FPM)

`compose.yaml` is itself a 3-layer reverse-proxy/micro-tracing chain per request:

```
client -> caddy (:80) -> nextcloud-nginx (:80) -> nextcloud-app PHP-FPM (:9000)
```

- `caddy` — public edge (TLS upstream: Tailscale Funnel / external proxy), does
  gzip + static caching, routes `/standalone-signaling` to the HPB.
- `nextcloud-nginx` — stock nginx; serves static files from the webroot, does
  the Nextcloud rewrite rules/`.well-known`/OCS routing, security headers, and
  proxies PHP to the FPM pool. Its config is `config/nginx.conf`.
- `nextcloud-app` — `nextcloud:stable-fpm`; renders PHP, auto-scales its FPM
  pool from `APP_MEM_LIMIT` (AIO-style). Its config is rendered at boot by
  `config/fpm-entrypoint.sh`.

`nextcloud-app` deliberately has **no `container_name`** so it can be scaled with
`--scale nextcloud-app=N`; nginx round-robins the FPM pool across replicas.

### 12.3 Command matrix

```bash
# bring the whole thing up (the only "composite deploy" command pair)
docker compose -f compose.db.yaml up -d          # 1) stateful ALWAYS first
docker compose up -d --remove-orphans            # 2) app tier (incl. nginx, cron, Talk, caddy)

# optional TURN relay overlay (native Linux only)
docker compose -f compose.yaml -f compose.turn.yaml up -d

# status / logs
docker compose ps
docker compose -f compose.db.yaml ps
docker compose logs -f nextcloud-app

# stop (reverse order: app tier first, then stateful)
docker compose down
docker compose -f compose.db.yaml down

# scale the web tier (never scale the stateful tier)
docker compose up -d --scale nextcloud-app=2
```

> **Never `--scale` `nextcloud-db` or `nextcloud-redis`** — those are singletons
> in `compose.db.yaml`; scaling the web tier is what the split is for.

## 13. Optional: extra app replica

`APP_REPLICAS` defaults to **1** (the minimum). Add replicas only when the host
has the RAM and metrics justify it (see [SCALING.md](SCALING.md) - on <= 16 GB
hosts keep 1 replica):

```bash
docker compose up -d --scale nextcloud-app=2
```

## 14. Backups

Set up the daily backup described in [BACKUP.md](BACKUP.md) **before** onboarding users.

## 15. Everyday operations

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

## 16. Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `network nextcloud-network not found` | Run `docker network create nextcloud-network` once |
| 500 on first load | `docker compose logs nextcloud-app`; DB not started yet or `POSTGRES_PASSWORD` empty - start `compose.db.yaml` first |
| App can't reach `nextcloud-db` / DB errors at boot | Start the database project first: `docker compose -f compose.db.yaml up -d` |
| "Please contact your administrator ... edit the trusted_domains setting" | The real domain is missing from `NEXTCLOUD_TRUSTED_DOMAINS` in `.env` (install succeeded but the browser host isn't trusted). Put your actual domain in as the last entry (`localhost 127.0.0.1 nextcloud <your-domain>`), fix `NC_DOMAIN` (no trailing slash), then recreate the app container so the entrypoint regenerates `config.php` |
| App container restarts / OOM | Lower `APP_MEM_LIMIT` in `.env` (FPM derives `pm.max_children` from it; total children x ~150 MB must stay below the limit), or raise the host RAM |
| `nextcloud-turn` never starts / machine lags on `up` | The 16k UDP relay range (`49152-65535`) is no longer in the main compose file - it hangs on Docker Desktop and is slow on Linux. Use the small optional override only on native Linux when you need TURN relay: `docker compose -f compose.yaml -f compose.turn.yaml up -d` |
| Talk no audio / no signaling | Verify `talk:signaling:list` / `talk:turn:list`; 3478 UDP/TCP reachable; host RAM (see small-host profile in [SCALING.md](SCALING.md)) |
| Site not reachable on `https://<host>.ts.net` | Funnel not running / the browser needs the exact hostname. Check `tailscale status` for the assigned `*.ts.net` name, then `tailscale funnel --bg http://127.0.0.1:80` and confirm `NC_DOMAIN`/`NEXTCLOUD_TRUSTED_DOMAINS` use that exact name (no trailing slash) - recreate the app container after changing them |
| `tailscale` not found | Install it: `curl -fsSL https://tailscale.com/install.sh | sh` and re-authenticate with `sudo tailscale up` (step 6) |
| Host OOM-kills containers despite limits | Add swap (`fallocate -l 8G /swapfile` on Ubuntu); aux services carry `oom_score_adj: 500` so the app/Talk tier dies last |
| Uploads stuck at 512 MB | Keep `upload_max_filesize`/`post_max_size` in `config/php-custom.ini` in sync with `UPLOAD_MAX_SIZE` in `.env` (both default `2G`) and the nginx `client_max_body_size` in `config/nginx.conf`, then recreate the app + nginx containers |
| App page won't render / "extension" console errors (e.g. Apps, Settings) | Browsers cache the `.mjs` chunks by MIME; after changing `config/nginx.conf` MIME/`location` rules do a **hard refresh** (`Ctrl+Shift+R`) or clear site data for your domain - cached modules keep the old `application/octet-stream` label and refuse to run |
| Sessions lost on scaling | Confirm `REDIS_HOST` is set on the app (image writes the PHP session handler to Redis) |