# Scaling guide

Goal: comfortably serve ~400 users and know exactly when and how to add capacity.

## What is already stateless

The app tier uses the AIO-style runtime model with stock images: **PHP-FPM** inside
`nextcloud-app` renders all requests and auto-scales its worker pool (`pm`) to match
`APP_MEM_LIMIT`, and a stock **nginx** sidecar (`nextcloud-nginx`) serves static files
and proxies PHP to `nextcloud-app:9000`. This replaces the old Apache+mod_php tier whose
prefork worker-count env expansion was unreliable and serialized concurrent requests
(the source of the "slow as hell" symptoms).

`nextcloud-app` is also designed to be scaled horizontally on purpose:

| Concern | Where it lives |
| --- | --- |
| PHP sessions | Redis (the nextcloud image writes `session.save_handler = redis` automatically when `REDIS_HOST` is set) |
| Distributed cache | Redis (`memcache.distributed`) |
| File locking | Redis (`memcache.locking`) |
| Local cache | APCu (`memcache.local`, built into the image) |
| Webroot + data | shared named volume `nextcloud` (mounted read-write in app + cron) |
| Database | single shared PostgreSQL, run in the standalone `compose.db.yaml` project (never scaled) |
| Background jobs | the single `nextcloud-cron` container |

So adding app replicas is safe: sessions and locks survive across every instance.

The database is a **singleton** and lives in its own Compose project
(`compose.db.yaml`). Replicas never get their own database, so scaling back down
never needs to merge anything. Never run `--scale` on `postgres-db` or
`nextcloud-redis` - stateful services must stay at exactly one copy each.

## Add replicas (single host, Docker Compose)

Sizing is **env-driven**, not hardcoded: the compose files read `APP_*` / `DB_*`
/ `REDIS_*` / per-service `*_MEM_LIMIT` variables from `.env` (see `.env.example`
for the small-host and standard presets). Change sizes there, then:

```bash
# scale up (2-3 app containers)
docker compose up -d --scale nextcloud-app=3

# check
docker compose ps

# scale back down to one (do this before an upgrade)
docker compose up -d --scale nextcloud-app=1
```

`APP_REPLICAS` is the **minimum replica floor** (default `1`) and must never be
raised on a <= 16 GB host: memory budget, not CPU, is what caps replicas. See
[Scale on demand](#scale-on-demand--small-host-profile) below.

Caddy proxies to the `nextcloud-app` sidecar `nextcloud-nginx`, which serves static files and
proxies PHP to the FPM pool on `nextcloud-app:9000`. Docker's embedded DNS resolves
`nextcloud-app` across every replica's IP, so FPM round-robins automatically - no Caddyfile
change is needed. Replicas share the webroot volume; do not run `occ` from more than one container at a time.

### How many replicas?

With the size presets, sizing is a table read rather than a guess:

| Host RAM | `APP_MEM_LIMIT` | `APP_FPM_MAX_CHILDREN` | `APP_REPLICAS` | Users (Talk on) |
| --- | --- | --- | --- | --- |
| 8 GB | 3G | auto (~20) | 1 (max) | 25-75 light |
| 16 GB | 4G | auto (~27) | 1 | 75-150 |
| 32 GB | 8G | auto (~54) | 1 | 150-300 |
| 64 GB | 8G | auto (~54) | 2 | 300-400 |

`APP_FPM_MAX_CHILDREN` is optional: leave it empty and the entrypoint derives `pm.max_children`
from `APP_MEM_LIMIT` at ~150 MB per child (3G -> ~20; 8G -> ~54). Override it in `.env` only if
you calibrate per child. The total (children x ~150 MB) must stay under `APP_MEM_LIMIT`. If a
replica starts OOM-killing, raise the limit or lower the child count - do not just add replicas
with a bloated pool.

## Upgrades with replicas

1. `docker compose up -d --scale nextcloud-app=1`
2. `docker compose pull && docker compose up -d --remove-orphans`
3. `docker exec -u www-data nextcloud-app php occ upgrade`
4. `docker compose up -d --scale nextcloud-app=N`

Every app replica runs the image entrypoint, which serializes `occ upgrade`/install behind a lock file on the shared volume, but it is still safer to bring the web tier to a single replica during an upgrade (maintenance mode is handled by `occ`).

## Scale on demand + small-host profile

**The rule: minimum 1 replica, scale only when needed.** `APP_REPLICAS=1` is the
floor and the correct setting for any host up to ~16 GB. Add replicas only when
monitoring shows a sustained reason:

- `docker stats`: app at/above **80% CPU** for 15+ minutes, or app RSS close to
  `APP_MEM_LIMIT` while the host still has free RAM.
- If the host is already near its memory ceiling, do **not** add replicas - add
  RAM/swap or move users first. On an 8 GB box, 1 replica is the maximum.

```bash
docker compose up -d --scale nextcloud-app=N   # when the box can actually host it
docker compose up -d --scale nextcloud-app=1   # back to the floor
```

### I have a small 8 GB host and must keep Talk

With 8 GB the container limits of the whole stack must add up to less than the
physical RAM (plus the OS and the kernel page cache). The small presets in
`.env.example` do exactly that:

| Service | Limit | Notes |
| --- | --- | --- |
| nextcloud-app | 3G / auto pool (~20 children) | biggest single consumer; trimmed from 8G |
| nextcloud-nginx | 256M | static file server + PHP proxy, stateless |
| nextcloud-cron | 512M | background jobs only |
| signaling | 1G | kept at full size - Talk is the priority |
| turn | 512M | kept at full size - Talk is the priority |
| caddy | 256M | reverse proxy, stateless |
| postgres-db | 2G (`shared_buffers=512M`) | singleton, in `compose.db.yaml` |
| nextcloud-redis | 512M (`maxmemory 512mb`) | singleton, in `compose.db.yaml` |

Aux services (cron, signaling, turn, caddy) also get `oom_score_adj: 500` in
`compose.yaml`, so if the host ever exhausts RAM the kernel kills an auxiliary
container before it ever touches the web tier or Talk. Add **swap** on the host
(fresh hint for Ubuntu: `fallocate -l 8G /swapfile`) as a last-resort buffer so
brief spikes do not reach the OOM killer at all.

Apply with:

```bash
cp .env.example .env               # then fill in secrets AND sizes
docker compose -f compose.db.yaml up -d   # DB + Redis first
docker compose up -d --remove-orphans
docker exec -u www-data nextcloud-app php occ status
docker exec -u www-data nextcloud-app php occ talk:signaling:list
docker exec -u www-data nextcloud-app php occ spreed:turn:list
```

Watch `docker stats` and `free -h`; check for OOM kills with `dmesg | grep -i oom`.

### Going back to the big profile later

When the host is resized to 32-64 GB, uncomment the **Preset B** block in
`.env.example` over Preset A, restart the stack, and you can then scale to 2
replicas. Nothing else in the repo changes - that is the point of env-driven
sizing.

## Real elastic autoscaling - read this before you over-engineer

Docker Compose on a single host **cannot** autoscale on CPU/memory load. The options, honest version:

### Option 1 (recommended for now): manual scaling + monitoring
Keep `--scale` manual and alert on metrics (see README > Monitoring). For one machine hosting 400 users, this is the right amount of complexity. Autoscaling on a single host mostly means the node is already too small - add RAM/CPU or spread to more than one server first.

### Option 2: Docker Swarm
The compose file already carries `deploy.replicas` / `deploy.resources` blocks which Swarm honors. `docker service scale nextcloud-app=4` adjusts replicas at runtime (still manual or cron-driven). Swarm needs NFS/shared storage for the `nextcloud` volume - local volumes do not float between nodes.

### Option 3: Kubernetes (HPA)
Kubernetes + HorizontalPodAutoscaler can add replicas on CPU/memory. This is the only true autoscale. It requires:
- shared filesystem (NFS/CephFS/EFS) or object storage (S3 primary storage) for data,
- managed PostgreSQL + Redis (or statefulsets), and
- moving Talk + backup + monitoring into the cluster idiom.

For a 400-user organization starting today, Option 1 is the pragmatic path. Revisit when you plan multiple nodes or >800 users.

## Sizing recap

| Component | Value in this repo (default / small-8GB profile) |
| --- | --- |
| Host RAM | >= 8 GB for the small profile; >= 32 GB for ~400 users (64 GB if 2 app replicas + Talk) |
| App | `APP_MEM_LIMIT=3G` / FPM auto pool (small); 8G / auto (standard; >16 GB host). Optionally pin `APP_FPM_MAX_CHILDREN`. |
| DB | `DB_MEM_LIMIT=2G`, `DB_SHARED_BUFFERS=512M`, `DB_MAX_CONNECTIONS=60` (in `compose.db.yaml`) |
| Redis | `REDIS_MEM_LIMIT=512M`, `REDIS_MAXMEMORY=512mb` (in `compose.db.yaml`) |
| Data disk | SSD/NVMe, monitor with `df -h` and `docker system df` |