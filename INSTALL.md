# Installation guide

This guide deploys the `compose.yaml` stack from scratch on a **single Docker host** -
Ubuntu (Docker Engine) or Windows (Docker Desktop / WSL2). Both tracks are given
side by side so you can follow one to the end.

**Start order is the one thing to get right.** The stack splits into two Compose
projects, and they must come up in this order:

1. the **shared network** (one-time) - `nt_n8n_network`
2. the **stateful project** - `compose.db.yaml` (PostgreSQL + Redis) - ALWAYS FIRST
3. the **app project** - `compose.yaml` (Nextcloud, cron, Talk signaling/TURN, Caddy)

Caddy is part of the app project (step 3). It reads the `Caddyfile` when it
starts, so finish the **DNS / TLS choice (step 6) before first start**.

---

## 0. Quick orientation

| Project | File | Services | Starts |
| --- | --- | --- | --- |
| `db-services` | `compose.db.yaml` | `postgres-db`, `nextcloud-redis` | **1st (always)** |
| `nextcloud-stack` | `compose.yaml` | `nextcloud-app`, `nextcloud-cron`, `signaling`, `turn`, `caddy` | 2nd |

Both connect over the single external network `nt_n8n_network`.

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

Both projects expect an **external** network named `nt_n8n_network`. Create it
once (any OS):

```bash
docker network create nt_n8n_network
```

If you ever see `network nt_n8n_network not found`, re-run this exact command.

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

Every value below **must** be filled in before first start. The two things that
silently break installs are **(1) leaving the `nextcloud.example.com` placeholder**
and **(2) a trailing `/` on `NC_DOMAIN`**.

### What to set, line by line

> Fill in at least the secrets and domain. To generate passwords on Ubuntu use
> `openssl rand -base64 24`; on Windows use the PowerShell one-liners in the
> Talk secrets section below.

| `.env` line | What to put | Gotcha |
| --- | --- | --- |
| `POSTGRES_PASSWORD=` | a long random password | used **only on first DB boot**; changing it later needs a DB reset |
| `NEXTCLOUD_ADMIN_USER=/ADMIN_PASSWORD=` | your Nextcloud admin login | used only if install is done via the web installer |
| `NC_DOMAIN=` | your public domain, **no scheme** | **NO trailing slash** - `…/` breaks it |
| `OVERWRITECLIURL=` | `https://` + your domain | used so CLI/`occ` builds https links |
| `OVERWRITEPROTOCOL=` | `http` or `https` | `https` when TLS is terminated in front (Funnel/Direct LE) |
| `NEXTCLOUD_TRUSTED_DOMAINS=` | `localhost 127.0.0.1 nextcloud <your-domain>` | **must end with your real domain, not the placeholder** |
| `TRUSTED_PROXIES=` | the docker subnet | `docker network inspect nt_n8n_network` (default `172.16.0.0/12`) |
| `TURN_SECRET/SIGNALING_SECRET/INTERNAL_SECRET=` | 3 random base64 | must match what the signaling/TURN containers get |
| `BLOCK_KEY=` / `HASH_KEY=` | random hex | sizes shown in the secrets section below |

### Worked example (Tailscale Funnel, `.ts.net`, no real cert)

Replace every `nextcloud.example.com` and every `<your-host>.ts.net` with your
actual hostname (found via `tailscale status`, step 6):

```bash
NC_DOMAIN=mis-server.tail204a2d.ts.net          # NO trailing slash, NO scheme
OVERWRITECLIURL=https://mis-server.tail204a2d.ts.net
OVERWRITEPROTOCOL=https
NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1 nextcloud mis-server.tail204a2d.ts.net
TRUSTED_PROXIES=172.16.0.0/12
```

> **Verify before continuing - run `grep` and confirm:**
>   - `NC_DOMAIN=` has **no trailing `/`** (the line must not end in `/`),
>   - `NEXTCLOUD_TRUSTED_DOMAINS=` ends with `mis-server.tail204a2d.ts.net`
>     (not `nextcloud.example.com`).
>
> Commands:
> ```bash
> grep '^NC_DOMAIN=' .env
> grep '^NEXTCLOUD_TRUSTED_DOMAINS=' .env
> ```
>
> If either is wrong, fix `.env` and recreate the app container (step 7) - the
> values are read at container start, **not** from a running container. Leaving
> the placeholder or a trailing slash makes the browser show **"Please contact
> your administrator ... edit the trusted_domains setting"** even though the
> install succeeded - it is the single most common install failure.

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

> **Run `occ` via the service name, NOT the container name.** The actual app
> container is prefixed with the project name (e.g. `nextcloud-stack-nextcloud-app-1`)
> and the prefix changes with the folder name, so a hard-coded
> `docker exec nextcloud-app …` fails with **`Error response from daemon: No such
> container: nextcloud-app`**. Always use `docker compose exec nextcloud-app …`
> - that resolves the real container for you. To confirm the app container first:
> `docker compose ps`.

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

Run these **only after the install has completed** (`occ status` shows
`installed: true`). The signals are exchanged over the public domain.
`nextcloud-app` has no fixed container name (so it can be `--scale`d), so run
`occ` via the service name.

**Step 1 - confirm install is done (skip this step if it is):**

```bash
docker compose exec nextcloud-app php occ status
# must print:  - installed: true
```

If it prints `installed: false` / "Nextcloud is not installed", finish the
web installer first (step 8) - the `talk:` commands do **not** exist until then.

**Step 2 - grab your real domain and secret from `.env`.**

Note down the exact values - do **not** type the literal strings `<NC_DOMAIN>`
or `<SIGNALING_SECRET>`; those are placeholders. `SIGNALING_SECRET` below **must
equal** the `SIGNALING_SECRET=` line in `.env`:

```bash
grep -E '^(NC_DOMAIN|SIGNALING_SECRET)=' .env
```

**Step 3 - register the signaling server.**

> NC 34+ uses the `talk:` namespace (the old `spreed:*` commands were renamed).
> The `<server>` argument is the **WebSocket** URL the browser talks to. Over
> Tailscale Funnel / TLS-terminated edge this is `wss://<NC_DOMAIN>/standalone-signaling`
> (the `Caddyfile` already proxies `/standalone-signaling` to the signaling
> container on `:8081`).

Copy the **completed example** below and edit **only the underlined parts** - the
secret and the domain. The angle brackets are **never typed**; they only mark
"put your value here":

```bash
docker exec -u www-data nextcloud-app php occ talk:signaling:add \
  "wss://<NC_DOMAIN>/standalone-signaling" <SIGNALING_SECRET> --verify
```

**Filled-in example** (domain `mis-server.tail204a2d.ts.net`, secret
`X9wVE4b8/teDicCr1BR2e6WFFrv+hU+KxGxpFxBBYT8=`). Copy it, swap in **your**
domain and **your** secret from step 2, and run:

```bash
docker exec -u www-data nextcloud-app php occ talk:signaling:add \
  "wss://mis-server.tail204a2d.ts.net/standalone-signaling" \
  "X9wVE4b8/teDicCr1BR2e6WFFrv+hU+KxGxpFxBBYT8=" \
  --verify
```

- **No angle brackets** around the secret - paste the value itself (wrap it in
  double quotes, as it contains `/` and `+` which the shell would otherwise
  split on).
- The three argument parts are in **this exact order**: the `wss://…` URL, then
  the secret, then `--verify`.
- `--verify` validates the SSL certificate (correct for real TLS). For an
  internal-only HTTP setup, set `SKIP_VERIFY=true` on the signaling service and
  omit `--verify`.

**Step 4 - check it registered:**

```bash
docker exec -u www-data nextcloud-app php occ talk:signaling:list
```

### 11.3 Register TURN

> Argument order is: **schemes, then server, then `udp,tcp`, then `--secret=`.
> The `--secret=` value has no space after the `=` and no angle brackets.**

```bash
# schemes: `turn` (or `turn,turns`); protocols: `udp,tcp`; --secret = TURN_SECRET
docker exec -u www-data nextcloud-app php occ talk:turn:add \
  turn # # #  # # --secret=# # #    # <-- template; fill in below
```

Same idea as 11.2 - copy the filled-in example and swap in your domain and TURN
secret:

```bash
docker exec -u www-data nextcloud-app php occ talk:turn:add \
  turn mis-server.tail204a2d.ts.net udp,tcp \
  --secret=X9wVE4b8/teDicCr1BR2e6WFFrv+hU+KxGxpFxBBYT8=
```

- `schemes` = `turn` (TURN only) or `turn,turns` (TURN + TURNS over TLS).
- `server` = the plain domain - **no scheme** (e.g. `mis-server.tail204a2d.ts.net`,
  not `https://…`).
- `--secret=` value goes **directly after the `=`**, no space, no angle brackets.

Verify with:

```bash
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
| `compose.db.yaml` | `db-services` | PostgreSQL (`postgres-db`) + Redis (`nextcloud-redis`) — **singletons** | Always first |
| `compose.yaml` | `nextcloud-stack` | `nextcloud-app` (PHP-FPM), `nextcloud-nginx`, `nextcloud-cron`, `signaling`, `turn`, `caddy` | Always second |
| `compose.turn.yaml` (override) | `nextcloud-stack` (merged into `compose.yaml`) | TURN **relay** UDP port range for media | Only on native Linux, only if clients need a real relay |

### 12.1 Two projects, one shared network

Both projects connect over the single external network `nt_n8n_network`
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

> **Never `--scale` `postgres-db` or `nextcloud-redis`** — those are singletons
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
`docker network create nt_n8n_network`.

## 16. First deploy on Ubuntu (quick runbook)

The full step-by-step is above; this is the condensed order on a fresh Ubuntu
server, chaining the commands that matter (assumes `docker` installed and
enabled as a **systemd daemon** - `sudo systemctl enable --now docker`).

```bash
# 1. Pull and configure
git clone https://github.com/miel-R/nextcloud-stock-customs.git
cd nextcloud-stock-customs
cp .env.example .env
nano .env          # secrets + real domain (no trailing slash, no placeholder) - see step 5

# 2. If anything already holds :80 (system apache2/nginx), free it first
sudo ss -tlnp | grep :80        # shows the offender
sudo systemctl stop apache2 && sudo systemctl disable apache2 && sudo pkill -f apache2

# 3. Network + DB/Redis first, then the app tier
docker network create nt_n8n_network
docker compose -f compose.db.yaml up -d
docker compose up -d --remove-orphans

# 4. Finish the web installer (creates the admin, sets installed:true)
#    open https://<NC_DOMAIN>/ in the browser, hard refresh (Ctrl+Shift+R)

# 5. Register the HPB + TURN (only after occ status shows installed: true)
docker compose exec nextcloud-app php occ status
docker compose exec nextcloud-app php occ talk:signaling:add \
  "wss://<NC_DOMAIN>/standalone-signaling" <SIGNALING_SECRET> --verify
docker compose exec nextcloud-app php occ talk:turn:add \
  turn <NC_DOMAIN> udp,tcp --secret=<TURN_SECRET>
```

> Run `occ` with `docker compose exec nextcloud-app …` (service name), **not**
> `docker exec nextcloud-app …` - the real container name carries a project
> prefix (`nextcloud-stack-nextcloud-app-1`) that changes per folder. See the
> step 11 note and the `No such container` row in troubleshooting.

## 17. Troubleshooting

If an issue happens, how it should behave is documented in the steps referenced
in the second column - "should not happen because" points to where the correct
behaviour is defined.

| Symptom | Should not happen because ... | Likely cause / fix |
| --- | --- | --- |
| `network nt_n8n_network not found` | ... step 6 creates it once | Run `docker network create nt_n8n_network` (see step 6) |
| `failed to bind host port 0.0.0.0:80/tcp: address already in use` (or you see another web server's default page at `http://<host>:80`) | ... this stack needs `:80` free for Caddy | Another process holds port `:80` (usually system apache2/nginx). Confirm with `sudo ss -tlnp \| grep :80`, then `sudo systemctl stop apache2 && sudo systemctl disable apache2 && sudo pkill -f apache2`, recreate Caddy `docker compose up -d --remove-orphans`, re-check `ss` shows Caddy, hard refresh (`Ctrl+Shift+R`) |
| 500 on first load / App can't reach `postgres-db` | ... step 6 starts the DB project first, so the app never races the DB | Start `compose.db.yaml` first, then the app: `docker compose -f compose.db.yaml up -d && docker compose up -d --remove-orphans` (step 6) |
| "Please contact your administrator ... edit the trusted_domains setting" | ... step 5 has you put the real domain last in `NEXTCLOUD_TRUSTED_DOMAINS` and drop the trailing `/` | Domain is missing/typo'd in `.env`. Put your real domain as the last entry (no placeholder, no trailing slash), recreate the app so the entrypoint regenerates `config.php` (step 5, 7) |
| `occ status` says `installed: false` / "Nextcloud is not installed" (or `Error while trying to create admin account ... password authentication failed`) | ... step 5 sets the correct domain and a matching `POSTGRES_PASSWORD`, and step 6 boots the DB before install | First-boot install never completed. Fix `.env` (correct domain, no slash). If the DB password changed since the volume's first init, reset the DB volume - it keeps its first password even after `down -v`. Force full reset: `docker compose -f compose.db.yaml down -v`, `docker volume rm <db-volume>` if it still lists, then `compose.db.yaml up -d`, recreate the app, open `https://<NC_DOMAIN>/` (hard refresh) (step 5, 8) |
| `Error response from daemon: No such container: nextcloud-app` | ... you should run `occ` via the service name `docker compose exec nextcloud-app …`, not `docker exec nextcloud-app …` | The real container name carries a project prefix (`nextcloud-stack-nextcloud-app-1`) that changes per folder. Use `docker compose exec nextcloud-app …`, or `docker ps --format '{{.Names}}'` to find the exact name (step 11 note) |
| App container restarts / OOM | ... sizing is chosen so children fit host RAM (SCALING.md) | Lower `APP_MEM_LIMIT` in `.env` (FPM derives `pm.max_children`; children x ~150 MB must stay under it), or add host RAM (step 5, [SCALING.md](SCALING.md)) |
| `nextcloud-turn` never starts / machine lags on `up` | ... TURN relay is off by default; the 16k UDP range is only in the optional override | The override hangs Docker Desktop and is slow on Linux - use it only on native Linux when you need relay: `docker compose -f compose.yaml -f compose.turn.yaml up -d` (step 11) |
| Talk no audio / no signaling | ... step 11 registers the HPB and TURN, and port 3478 is reachable | Verify `talk:signaling:list` / `talk:turn:list`; ensure 3478 UDP/TCP reachable; host RAM adequate (step 11, [SCALING.md](SCALING.md)) |
| Site not reachable on `https://<host>.ts.net` | ... step 6 runs Funnel and step 5 sets the exact `.ts.net` name as `NC_DOMAIN` + last trusted domain | Funnel not running, or wrong hostname in `.env`/browser. `tailscale status` for the name, `tailscale funnel --bg http://127.0.0.1:80`, fix `NC_DOMAIN`/`NEXTCLOUD_TRUSTED_DOMAINS` (no slash), recreate the app (step 5, 6) |
| `tailscale` not found | ... step 6 installs Tailscale | `curl -fsSL https://tailscale.com/install.sh \| sh`, then `sudo tailscale up` (step 6) |
| Host OOM-kills containers despite limits | ... the sizing profile matches host RAM, and auxiliary services carry `oom_score_adj: 500` so the app/Talk tier dies last | Add swap (`fallocate -l 8G /swapfile` on Ubuntu) or raise RAM to the profile's target (step 5, [SCALING.md](SCALING.md)) |
| Uploads stuck at 512 MB | ... `UPLOAD_MAX_SIZE`, `php-custom.ini`, and nginx `client_max_body_size` are kept in sync (step 5) | Align `upload_max_filesize`/`post_max_size` with `UPLOAD_MAX_SIZE` (both default `2G`) and nginx `client_max_body_size`, recreate the app + nginx (step 5, 7) |
| App page won't render / "extension" console errors (e.g. Apps, Settings) | ... the nginx config ships the correct `.mjs` MIME type and front-controller routing | Browsers cache old `application/octet-stream` labels - hard refresh (`Ctrl+Shift+R`) or clear site data so the `.mjs` modules reload with the correct MIME (step 7 / `config/nginx.conf`) |
| Sessions lost on scaling | ... `REDIS_HOST` is set on the app so PHP sessions live in Redis | Confirm `REDIS_HOST` on the app (image writes the session handler to Redis); recreate the app after changing it (step 5) |