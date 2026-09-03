# n8n integration (separate stack, shared PostgreSQL)

How to run an **n8n** automation instance next to the Nextcloud stack. n8n runs
in its **own Compose project (`n8n_stack`, `compose.n8n.yaml`)** but uses the
**same PostgreSQL server** as Nextcloud — no second Postgres.

> n8n here is **optional**. Everything below is additive: n8n is a standalone
> stack, so the Nextcloud/DB stacks run unchanged with or without it.

---

## The model

```
┌──────────────────────────── nextcloud-network ─────────────────────────────┐
│                                                                             │
│   ┌─────────────── nextcloud-db (postgres:16-alpine) ───────────────┐      │
│   │   database  nextcloud    (owned by nextcloud user)              │      │
│   │   database  n8n          (owned by n8n user)   <- same instance │      │
│   └─────────────────────────────────────────────────────────────────┘      │
│                                                                             │
│   project: nextcloud-database   (compose.db.yaml)                           │
│     └─ nextcloud-db, nextcloud-redis                                       │
│                                                                             │
│   project: nextcloud          (compose.yaml)                                │
│     └─ nextcloud-nginx / nextcloud-app / ... (web tier)                     │
│                                                                             │
│   project: n8n_stack          (compose.n8n.yaml)   <- SEPARATE project      │
│     └─ n8n (127.0.0.1:5678 -> loopback only)                                │
│          └─ DB_TYPE=postgresdb ─► nextcloud-db:5432 / database=n8n / user=n8n│
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **One Postgres instance** (`nextcloud-db`) serves both the `nextcloud` and the
  `n8n` databases. n8n gets its **own database and user** — it never touches
  Nextcloud's tables.
- **n8n is its own Compose project** (`n8n_stack`). It joins the shared external
  `nextcloud-network` to reach `nextcloud-db`. Start/stop/upgrade it
  independently; `compose.db.yaml down` never stops n8n and vice versa.
- By default n8n binds **`127.0.0.1:5678`** (loopback only) — internal / tailnet
  only, NOT the public Funnel hostname. (Options to share the Funnel domain are
  documented in "Self-hosting both on one Funnel domain" below.)

---

## Why NOT "the same database" (literally)

Do **not** point n8n at Nextcloud's `nextcloud` database and `nextcloud` user.
Nextcloud owns that schema and its own role; sharing it risks collisions and
gives n8n privileges it should not have. "Same database" here means **same
server, separate database and role** — that is the correct, safe model.

## Self-hosting both on one Funnel domain

You asked: host both **n8n** and **Nextcloud** on the same Tailscale funnel
domain. Three realistic options, from simplest to most work:

### A. n8n internal-only (default here) — keep Nextcloud on the Funnel

- Nextcloud is the only thing served at `https://<NC_DOMAIN>/` through the
  Funnel (Caddy → `nextcloud-nginx`).
- n8n binds loopback (`127.0.0.1:5678`). Reach the wizard from a Tailnet client:
  `http://<this-host-tailnet-IP>:5678`, or with
  `ssh -L 5678:localhost:5678 <user>@<tailnet-ip>` then open localhost.
- Pros: safest (n8n editor/creds never public), no proxy complexity. This is the
  stack default.

### B. n8n under a subpath on the same domain (`/n8n/`)

n8n **cannot** reliably run on a subpath in current releases (editor, WS/SSE
push, redirects ignore the base path) — see n8n GitHub issue
[n8n-io/n8n#19635](https://github.com/n8n-io/n8n/issues/19635). Fragile proxy
rewrites are required and still break features like Human-in-the-Loop. **Not
recommended.**

### C. Dedicated subdomain for n8n, proxied through Caddy (recommended for public n8n)

Give n8n its own DNS name (e.g. `n8n.example.com`, or a second Tailscale
hostname that resolves to this host) and reverse-proxy it through the **same
Caddy**. Every service keeps its **own root** (no subpath bug) while sharing
one Caddy/funnel entry point on :443.

The plumbing is already in the repo; enable it like this:

1. **`compose.n8n.yaml`** — comment out the `ports:` (loopback) line so n8n is
   reachable only on `nextcloud-network` (Caddy, also on that network, reaches
   it internally; it stays unreachable from the internet directly). Set the
   public URL vars (`.env`):

```yaml
services:
  n8n:
    # ports:                        # <-- comment this out for proxied access
    #   - "127.0.0.1:5678:5678"
    environment:
      - N8N_HOST=${N8N_HOST:-}      # e.g. n8n.example.com
      - N8N_PROTOCOL=${N8N_PROTOCOL:-https}
      - N8N_PORT=${N8N_PORT:-5678}
```

   Set those in `.env`:
   ```bash
   N8N_HOST=n8n.example.com
   N8N_PROTOCOL=https
   N8N_PORT=5678
   ```

2. **`Caddyfile`** — uncomment the n8n routing block, which matches the n8n host
   and proxies to the n8n container (already joins `nextcloud-network`). Provide
   the hostname via the `N8N_DOMAIN` variable passed to Caddy:

```caddyfile
# inside the :80 site block:
{@n8n} host {$N8N_DOMAIN}          # or the literal hostname

handle @n8n {
    reverse_proxy n8n-n8n-1:5678 {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-For {remote_host}
        header_up Origin {scheme}://{host}
    }
}
```

   `n8n-n8n-1` is the Compose container name for the `n8n_stack` project
   (`<project>-<service>-<n>`). Because Caddy is HTTP-only (TLS via Funnel), the
   n8n hostname must be covered by the **same Funnel route** so the Host header
   reaches Caddy.

3. **Tailscale** — Funnel serves one node. Put n8n's name on the Funnel route or
   a second tailnet node that forwards to this host; Caddy then routes by the
   `N8N_DOMAIN` Host header to n8n while Nextcloud stays on the main hostname.

> A **single** Tailscale funnel hostname with Nextcloud on `/` cannot also serve
> n8n cleanly — the subpath route is broken (n8n-io/n8n#19635). A separate
> resolvable hostname through the same Caddy (Option C) is the supported way to
> have both on the Funnel.

> Further reading: n8n self-hosting / proxy docs — "security: authentication",
> `N8N_HOST` / `N8N_PROTOCOL` / `N8N_PORT` env reference.

---

## 0. Enable / disable n8n with one .env toggle (no compose edits)

The n8n service lives in its own file (`compose.n8n.yaml`) behind a Compose
**profile named `n8n`**. You control it entirely from `.env` — you never need
to comment/uncomment compose:

```bash
# .env
N8N_INSTALL=true          # true = run n8n, false = do not
COMPOSE_PROFILES=n8n       # the mechanism; keep as "n8n"
```

- **`N8N_INSTALL=true`** → the active `COMPOSE_PROFILES=n8n` in `.env` makes
  `docker compose -f compose.n8n.yaml up -d` start n8n.
- **`N8N_INSTALL=false`** → set `COMPOSE_PROFILES=` (empty) so the `n8n` profile
  is off; the service stays defined but the stack starts nothing for it. It does
  not affect the Nextcloud app or DB stacks.
- The `n8n` profile only exists in `compose.n8n.yaml`, so `compose.yaml` and
  `compose.db.yaml` are unaffected either way.

---

## 1. Enable the database provisioning (one-time)

No separate n8n password is needed. The `n8n` login role is created with the
**same password string as `POSTGRES_PASSWORD`** (`config/init-n8n.sh` defaults
`N8N_DB_PASSWORD` to `POSTGRES_PASSWORD`). `N8N_DB_NAME` and `N8N_DB_USER`
default to `n8n`; they are listed (commented) in `.env` only if you want to
override them:

```bash
# .env (top of file, next to the database/admin secrets)
POSTGRES_PASSWORD=<the same value used everywhere>
# N8N_DB_NAME=n8n     # uncomment only to override the database name
# N8N_DB_USER=n8n     # uncomment only to override the role name
```

To use a **distinct** credential instead (optional), set `N8N_DB_PASSWORD` on
the `nextcloud-db` service env in `compose.db.yaml`; if you do, also set
`DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}` on the n8n service and keep the two
in sync.

The `nextcloud-db` service in `compose.db.yaml` already mounts
`config/init-n8n.sh` into `/docker-entrypoint-initdb.d/`. On the **first
initialization of an empty `nextcloud_db` volume**, that script creates the
`n8n` role and `n8n` database automatically.

> **If the data volume already exists** (e.g. you are on an existing
> install), the init script is **not** re-run - Postgres only runs init scripts
> once on an empty volume. In that case create the role + database manually:

```bash
docker compose -f compose.db.yaml exec nextcloud-db \
  psql -U nextcloud -d nextcloud -v N8N_USER="$N8N_DB_USER" -v N8N_PASS="$N8N_DB_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'N8N_USER') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', :'N8N_USER', :'N8N_PASS');
  END IF;
END $$;
SQL
docker compose -f compose.db.yaml exec nextcloud-db \
  psql -U nextcloud -d nextcloud -c \
  "CREATE DATABASE ${N8N_DB_NAME:-n8n} OWNER ${N8N_DB_USER:-n8n};"
```

> The `nextcloud` DB user is a **superuser** in the stock image, so it can
> create roles and databases. `config/init-n8n.sh` is idempotent (won't fail if
> the role/db already exist) and no-ops when `N8N_DB_PASSWORD` is empty, so it
> is safe to leave mounted even if you never use n8n.

---

## 2. The n8n service (its own stack: compose.n8n.yaml)

n8n lives in a **separate Compose file**, `compose.n8n.yaml`, whose project is
`n8n_stack`. It looks like:

```yaml
# compose.n8n.yaml (project: n8n_stack)
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: n8n_email_summarizer
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - GENERIC_TIMEZONE=Asia/Manila
      - NODE_ENV=production
      - N8N_PUSH_BACKEND=websocket
      # --- database: SAME Postgres instance, separate DB/user ---
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=nextcloud-db
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME:-n8n}
      - DB_POSTGRESDB_USER=${N8N_DB_USER:-n8n}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD:?err}
      - DB_POSTGRESDB_SCHEMA=public
    volumes:
      - ./n8n_data:/home/node/.n8n
    networks:
      - nextcloud-network

networks:
  nextcloud-network:
    external: true
    name: nextcloud-network
```

Key points baked in:

- **`127.0.0.1:5678:5678`** — loopback only. Not reached by the Funnel. (For
  public exposure, remove this and use the Caddy→ `n8n-n8n-1:5678` approach in
  "Self-hosting both on one Funnel domain".)
- **`DB_POSTGRESDB_HOST=nextcloud-db`** — the same container Nextcloud uses, on
  the same external `nextcloud-network`.
- **`DB_POSTGRESDB_DATABASE/USER/PASSWORD`** come from the `.env` vars in step 1.
- `DB_TYPE=postgresdb` is the modern n8n database driver variable.

Start it (the shared database project must already be up and the n8n role/db
must exist — step 1):

```bash
docker compose -f compose.db.yaml up -d      # shared Postgres+Redis (once)
docker compose -f compose.n8n.yaml up -d      # n8n_stack
```

---

## 3. Verify

```bash
# n8n is up and its port is bound on the host loopback
docker compose -f compose.n8n.yaml ps
#   n8n_email_summarizer ... Up ... 127.0.0.1:5678->5678/tcp

# it connected to the shared Postgres (look for DB connection, no errors)
docker compose -f compose.n8n.yaml logs --tail 20
```

Then open `http://<host>:5678` **from a client on the Tailnet** (not through the
public Funnel) to finish the n8n setup wizard.

---

## 4. Deploy both Nextcloud and n8n — full runbook (from scratch on Ubuntu)

Applies to a **clean host** (or a host where you do not mind the Postgres
volume being recreated). If the `nextcloud_db` volume already exists, follow
step 1's manual provisioning instead of the automatic init-script path.

### 4.1 Clone both repos

```bash
git clone https://github.com/miel-R/nextcloud-stock-customs.git
git clone https://github.com/miel-R/ami-nextcloud-talk.git   # optional Talk bot

cd nextcloud-stock-customs
cp .env.example .env
nano .env        # set POSTGRES_PASSWORD, NEXTCLOUD_ADMIN_*, NC_DOMAIN, OVERWRITE*,
                 # NEXTCLOUD_TRUSTED_DOMAINS, TRUSTED_PROXIES, Talk secrets
```

> `POSTGRES_PASSWORD` is the single secret used everywhere (n8n reuses it).
> See the stock `INSTALL.md` step 5 for the domain/secret rules (no trailing
> slash, no placeholder).

### 4.2 Free port 80 (if needed) and create the network

```bash
sudo ss -tlnp | grep :80          # is a system web server (apache2/nginx) holding :80?
sudo systemctl stop apache2 && sudo systemctl disable apache2 && sudo pkill -f apache2
docker network create nextcloud-network    # once
```

### 4.3 Validate config before starting

```bash
docker compose -f compose.db.yaml config -q   # DB + Redis
docker compose -f compose.n8n.yaml config -q  # n8n_stack (needs POSTGRES_PASSWORD)
```

### 4.4 Start the database project (Postgres + Redis)

On a **fresh** volume, `config/init-n8n.sh` runs during this first boot and
creates the `n8n` role + database automatically:

```bash
docker compose -f compose.db.yaml up -d
```

> If the init script ran, the n8n role/database already exist; skip the manual
> CREATE below. Confirm with:
> ```bash
> docker compose -f compose.db.yaml exec nextcloud-db \
>   psql -U nextcloud -d nextcloud -tAc "SELECT 1 FROM pg_roles WHERE rolname='n8n'"
> docker compose -f compose.db.yaml exec nextcloud-db \
>   psql -U nextcloud -d nextcloud -tAc "SELECT 1 FROM pg_database WHERE datname='n8n'"
> # each prints "1" (exists)
> ```

**Existing volume** — the init script will *not* run again, so create the n8n
role + database manually (same commands as step 1):

```bash
docker compose -f compose.db.yaml exec nextcloud-db \
  psql -U nextcloud -d nextcloud -c "CREATE ROLE n8n LOGIN PASSWORD '<POSTGRES_PASSWORD>'"
docker compose -f compose.db.yaml exec nextcloud-db \
  psql -U nextcloud -d nextcloud -c "CREATE DATABASE n8n OWNER n8n"
```

### 4.5 Start the web tier

```bash
docker compose up -d --remove-orphans
```

Finish the Nextcloud web installer at `https://<NC_DOMAIN>/` (hard refresh) —
this sets `installed: true`. Register Talk HPB/TURN per stock `INSTALL.md`
step 11 if you use it.

### 4.6 Start n8n (its own project) and finish its setup wizard

```bash
docker compose -f compose.n8n.yaml up -d
docker compose -f compose.n8n.yaml ps          # 127.0.0.1:5678->5678/tcp
docker compose -f compose.n8n.yaml logs --tail 20
```

From a **Tailnet client**, open `http://<host>:5678` and complete the n8n
first-run wizard. Because n8n uses the shared `nextcloud-db`, its data persists
in the same Postgres.

### 4.7 Result

- Nextcloud on the **Funnel domain** (`https://<NC_DOMAIN>/`).
- n8n on **loopback / tailnet only** (`http://<host>:5678`), sharing Postgres.
- Optional Ami bot on the same `nextcloud-network` (see `ami-nextcloud-talk`
  `INSTALL.md`).

---

## 5. Security & operations notes

- **Loopback only by design.** If you later want remote access, either expose it
  to the tailnet (preferred: reach it at `http://<host>:5678` from a Tailnet
  client while remaining unreachable to the internet) or funnel a **second**
  tailnet hostname to it — do not rely on `/n8n/` on the shared domain.
- **Backups.** n8n's Postgres data lives in the same `nextcloud_db` volume as
  Nextcloud's. Before/after this change, confirm your backup (BACKUP.md) covers
  it. n8n's own config/workflows also persist in `./n8n_data` (a bind mount),
  which is outside the container and covered by the same host backup.
- **Do not scale** the `nextcloud-db` service (singleton, see DATABASE.md).
- Removing n8n later: `docker compose -f compose.n8n.yaml down` and delete
  `./n8n_data` if you no longer need it.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| n8n fails to start: `role "n8n" does not exist` | The DB volume already existed so the init script never ran. Provision manually (step 1 "If the data volume already exists") and restart n8n (`docker compose -f compose.n8n.yaml restart`) |
| n8n starts but can't connect to Postgres (`connection refused`, host `nextcloud-db`) | The `nextcloud-db` container is not on `nextcloud-network`, or you started n8n before the DB project. Ensure `docker compose -f compose.db.yaml up -d` ran for the DB first |
| `password authentication failed for user "n8n"` | The n8n role's password does not match `POSTGRES_PASSWORD` (or the `DB_POSTGRESDB_PASSWORD` env). Re-provision the role to match |
| `no such service: n8n` when using `compose.db.yaml` | n8n no longer lives in `compose.db.yaml` — it is its own file. Use `docker compose -f compose.n8n.yaml up -d` |
| Editor loads but "Connection lost / Invalid origin" | Only relevant if you reverse-proxied n8n. Forward `Origin` / `X-Forwarded-*` headers (see "Self-hosting both on one Funnel domain", option C) |
| `/n8n/` or any subpath returns broken assets / 404 | n8n subpath hosting is unsupported (n8n-io/n8n#19635). Serve n8n at its own root/hostname, or run it internal-only as in this guide |
| n8n binds but is unreachable from the internet | Expected. It is loopback-only; reach it over the tailnet or funnel a dedicated (sub)domain via Caddy |