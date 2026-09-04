# Backup and restore

Two things make up a Nextcloud instance in this stack:

1. **Database** - volume `nextcloud_db` (PostgreSQL)
2. **Files** - volume `nextcloud_www` (Nextcloud webroot, `data/`, config, apps)

Redis and Caddy state are disposable (sessions/cache/config can be rebuilt).

## Backup strategy

### 1. Database (daily, logical dump)

```bash
docker exec postgres-db pg_dump -U nextcloud -d nextcloud -Fc \
  > /backup/postgres-db-$(date +%F).dump
```

Goes through the same container as the app, so no extra client needed (`docker exec postgres-db` works from anywhere because the container name is fixed). The database runs in the standalone project - the compose equivalent is `docker compose -f compose.db.yaml exec postgres-db pg_dump ...`. `-Fc` (custom format) is compressed and restore-friendly. Keep a few days on disk plus an off-site copy (rclone/borg).

### 2. Files (daily, consistent)

The `nextcloud_www` volume must be copied **while Nextcloud is in maintenance mode** so the DB and files stay in sync:

```bash
docker exec -u www-data nextcloud-app php occ maintenance:mode --on
# archive the volume (example: bind a host dir, or docker run a helper container)
docker run --rm -v nextcloud_www:/data:ro -v /backup:/backup alpine \
  tar -czf /backup/nextcloud-www-$(date +%F).tar.gz -C /data .
docker exec -u www-data nextcloud-app php occ maintenance:mode --off
```

If 400 users make a full maintenance window unacceptable:

- take a **volume snapshot** instead (LVM/ZFS/BTRFS or the cloud provider snapshot) - instant and consistent without maintenance mode, or
- do logical backups with `occ files:scan` on restore.

### 3. Automation

Example host cron (adjust paths):

```cron
30 2 * * * /opt/nextcloud-backup.sh >/var/log/nextcloud-backup.log 2>&1
```

```bash
#!/usr/bin/env bash
# /opt/nextcloud-backup.sh
set -euo pipefail
BACKUP_DIR=/backup/nextcloud
STAMP=$(date +%F)
mkdir -p "$BACKUP_DIR"

docker exec postgres-db pg_dump -U nextcloud -d nextcloud -Fc \
  > "$BACKUP_DIR/postgres-db-$STAMP.dump"

docker exec -u www-data nextcloud-app php occ maintenance:mode --on
docker run --rm -v nextcloud_www:/data:ro -v "$BACKUP_DIR":/backup alpine \
  tar -czf /backup/nextcloud-www-$STAMP.tar.gz -C /data .
docker exec -u www-data nextcloud-app php occ maintenance:mode --off

# retention: keep 7 daily dumps
find "$BACKUP_DIR" -name 'postgres-db-*.dump' -mtime +7 -delete
find "$BACKUP_DIR" -name 'nextcloud-www-*.tar.gz' -mtime +7 -delete
```

## Restore procedure

Test this on a staging host at least once before going live.

```bash
# 1. stop the web tier
docker compose up -d --scale nextcloud-app=0
docker exec -u www-data nextcloud-app php occ maintenance:mode --on   # if still running

# 2. database
docker exec -u www-data postgres-db \
  psql -U nextcloud -d nextcloud -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
cat postgres-db-YYYY-MM-DD.dump | \
  docker exec -i postgres-db pg_restore -U nextcloud -d nextcloud --clean --if-exists

# 3. files
docker run --rm -v nextcloud_www:/data -v "$(pwd)":/backup alpine \
  tar -xzf /backup/nextcloud-www-YYYY-MM-DD.tar.gz -C /data

# 4. start the database project if it is not running, then bring the app back
docker compose -f compose.db.yaml up -d
docker compose up -d
docker exec -u www-data nextcloud-app php occ maintenance:mode --off
docker exec -u www-data nextcloud-app php occ files:scan --all
```

## Notes

- Backups must be **off-host** (different disk, S3, NAS) to survive host failure.
- `nextcloud_www` includes the `data/` directory - estimate disk usage with `docker run --rm -v nextcloud_www:/data alpine du -sh /data`.
- If you later move primary storage to S3 (config in `config.php`), back up only `config`, `apps`, `data` minus external storage, and the DB - the S3 bucket becomes the file backup target itself.