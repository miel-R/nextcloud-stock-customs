# n8n integration (same PostgreSQL instance)

How to run an **n8n** automation instance next to the Nextcloud stack, using
the **same PostgreSQL server** as Nextcloud — no second Postgres.

> n8n here is **optional**. Everything below is additive: the `n8n` service is
> already in `compose.db.yaml` — you only need to set **three** env vars, and
> the n8n database is provisioned for you on first DB init.

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
│   n8n (127.0.0.1:5678 -> loopback only)                                    │
│     └─ DB_TYPE=postgresdb ─► nextcloud-db:5432 / database=n8n / user=n8n   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **One Postgres instance** (`nextcloud-db`) serves both the `nextcloud` and the
  `n8n` databases. n8n gets its **own database and user** — it never touches
  Nextcloud's tables.
- n8n is **internal-only**: it binds `127.0.0.1:5678` on the host and is reached
  over **Tailscale direct (tailnet)**, not the public Funnel hostname.

---

## Why NOT "the same database" (literally)

Do **not** point n8n at Nextcloud's `nextcloud` database and `nextcloud` user.
Nextcloud owns that schema and its own role; sharing it risks collisions and
gives n8n privileges it should not have. "Same database" here means **same
server, separate database and role** — that is the correct, safe model.

## Why n8n is NOT on the funnel domain

Given a **single Tailscale funnel hostname** (`ck1189.tail650e17.ts.net`),
serving n8n at a subpath like `/n8n/` would be the only way to share the
domain — but **subpath hosting of n8n is broken in current n8n**:

- n8n GitHub issue [n8n-io/n8n#19635](https://github.com/n8n-io/n8n/issues/19635):
  "in the current state of the code, n8n cannot actually run on a subpath
  without fragile proxy rewrites — and rewrites break features like
  Human-in-the-Loop."
- The editor, WebSocket/SSE push, and redirects do not honour a base path
  reliably.

So the robust options are a **dedicated hostname per service** (needs a second
tailnet node) or **leaving n8n internal-only**. This stack's default is the
latter - Funnel stays for Nextcloud, n8n is reachable only by admin clients on
the tailnet (e.g. `ssh -L` or a Tailnet client hitting `http://<host>:5678`).

---

## 1. Enable the database provisioning (one-time)

Set the three `N8N_DB_*` values in `.env` (from `.env.example`):

```
N8N_DB_NAME=n8n
N8N_DB_USER=n8n
N8N_DB_PASSWORD=<long random>     # openssl rand -base64 24
```

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

## 2. The n8n service (already in compose.db.yaml)

The `n8n` service is already defined in `compose.db.yaml` (enabled by default):

```yaml
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
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD:?set N8N_DB_PASSWORD in .env}
      - DB_POSTGRESDB_SCHEMA=public
    volumes:
      - ./n8n_data:/home/node/.n8n
    networks:
      - nextcloud-network
```

Key points baked in:

- **`127.0.0.1:5678:5678`** — loopback only. Not reached by the Funnel.
- **`DB_POSTGRESDB_HOST=nextcloud-db`** — the same container Nextcloud uses,
  on the same `nextcloud-network`.
- **`DB_POSTGRESDB_DATABASE/USER/PASSWORD`** come from the `.env` vars in step 1.
- `DB_TYPE=postgresdb` is the modern n8n database driver variable.

Start it (the database project must already be up):

```bash
docker compose -f compose.db.yaml up -d n8n
```

> The `${N8N_DB_PASSWORD:?...}` guard makes `docker compose ... config` fail
> until you set `N8N_DB_PASSWORD` in `.env` — this is intentional so n8n never
> starts without its password.

---

## 3. Verify

```bash
# n8n is up and its health/port is bound on the host loopback
docker compose -f compose.db.yaml ps n8n
#   n8n_email_summarizer ... Up ... 127.0.0.1:5678->5678/tcp

# it connected to the shared Postgres (look for DB connection, no errors)
docker compose -f compose.db.yaml logs n8n --tail 20
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
                 # NEXTCLOUD_TRUSTED_DOMAINS, TRUSTED_PROXIES, Talk secrets,
                 # and the n8n block: N8N_DB_PASSWORD
```

> `N8N_DB_PASSWORD` at the very least must be a real random value
> (`openssl rand -base64 24`). See the stock `INSTALL.md` step 5 for the
> domain/secret rules (no trailing slash, no placeholder).

### 4.2 Free port 80 (if needed) and create the network

```bash
sudo ss -tlnp | grep :80          # is a system web server (apache2/nginx) holding :80?
sudo systemctl stop apache2 && sudo systemctl disable apache2 && sudo pkill -f apache2
docker network create nextcloud-network    # once
```

### 4.3 Validate config before starting

```bash
docker compose -f compose.db.yaml config -q   # must succeed now (N8N_DB_PASSWORD set)
docker compose -f compose.db.yaml config -q n8n
```

### 4.4 Start the database project (Postgres + Redis). n8n is here too.

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
  psql -U nextcloud -d nextcloud -c "CREATE ROLE n8n LOGIN PASSWORD '<N8N_DB_PASSWORD>'"
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

### 4.6 Start n8n and finish its setup wizard

```bash
docker compose -f compose.db.yaml up -d n8n
docker compose -f compose.db.yaml ps n8n           # 127.0.0.1:5678->5678/tcp
docker compose -f compose.db.yaml logs n8n --tail 20
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
- Removing n8n later: `docker compose -f compose.db.yaml rm -sf n8n` and delete
  `./n8n_data` if you no longer need it.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| n8n fails to start: `role "n8n" does not exist` | The DB volume already existed so the init script never ran. Provision manually (step 1 "If the data volume already exists") and restart n8n |
| n8n starts but can't connect to Postgres (`connection refused`, host `nextcloud-db`) | The `nextcloud-db` container is not on `nextcloud-network`, or you started n8n before the DB project. Ensure `docker compose -f compose.db.yaml up -d` ran for the DB first |
| `password authentication failed for user "n8n"` | `N8N_DB_PASSWORD` in `compose.db.yaml` service env does not match the password the role was created with. Align `.env` and re-provision the role |
| Editor loads but "Connection lost / Invalid origin" | Only relevant if you tried to reverse-proxy n8n. For internal-only it does not occur. If behind a proxy, forward the `Origin` / `X-Forwarded-*` headers correctly |
| `/n8n/` or any subpath returns broken assets / 404 | n8n subpath hosting is unsupported (n8n-io/n8n#19635). Serve n8n at its own root/hostname, or run it internal-only as in this guide |
| n8n binds but is unreachable from the internet | Expected. It is loopback-only; reach it over the tailnet or funnel a dedicated hostname |