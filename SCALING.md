# Scaling guide

Goal: comfortably serve ~400 users and know exactly when and how to add capacity.

## What is already stateless

`nextcloud-app` is designed to be scaled horizontally on purpose:

| Concern | Where it lives |
| --- | --- |
| PHP sessions | Redis (the nextcloud image writes `session.save_handler = redis` automatically when `REDIS_HOST` is set) |
| Distributed cache | Redis (`memcache.distributed`) |
| File locking | Redis (`memcache.locking`) |
| Local cache | APCu (`memcache.local`, built into the image) |
| Webroot + data | shared named volume `nextcloud` (mounted read-write in app + cron) |
| Background jobs | the single `nextcloud-cron` container |

So adding app replicas is safe: sessions and locks survive across every instance.

## Add replicas (single host, Docker Compose)

```bash
# scale up (2-3 app containers)
docker compose up -d --scale nextcloud-app=3

# check
docker compose ps

# scale back down to one (do this before an upgrade)
docker compose up -d --scale nextcloud-app=1
```

Caddy proxies to the literal service name `nextcloud-app`. Docker's embedded DNS round-robins that name across every replica's IP, so no Caddyfile change is needed. Replicas share the webroot volume; do not run `occ` from more than one container at a time.

### How many replicas?

| Users | App replicas | App RAM each |
| --- | --- | --- |
| 100-200 | 1 | 8 GB |
| 200-400 | 2 | 8 GB |
| 400-800 | 2-3 | 8 GB (consider fpm + more CPUs) |

Watch `MaxRequestWorkers` in `config/apache-mpm.conf`: the total (workers x ~150 MB) must stay under the container memory limit. The current file is tuned for an 8G container / 60 workers. If a replica starts OOM-killing, either raise memory or lower the worker count - do not just add replicas with a bloated worker count.

## Upgrades with replicas

1. `docker compose up -d --scale nextcloud-app=1`
2. `docker compose pull && docker compose up -d --remove-orphans`
3. `docker exec -u www-data nextcloud-app php occ upgrade`
4. `docker compose up -d --scale nextcloud-app=N`

Every app replica runs the image entrypoint, which serializes `occ upgrade`/install behind a lock file on the shared volume, but it is still safer to bring the web tier to a single replica during an upgrade (maintenance mode is handled by `occ`).

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

## Sizing recap for 400 users

| Component | Value in this repo |
| --- | --- |
| Host RAM | >= 32 GB (64 GB if 2 app replicas + Talk) |
| App | 8G limit / 60 workers per replica |
| DB | 4G limit, `shared_buffers=1G`, `max_connections=150` |
| Redis | 1G limit, `maxmemory 1gb` |
| Data disk | SSD/NVMe, monitor with `df -h` and `docker system df` |