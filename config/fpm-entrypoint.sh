#!/bin/bash
# Entrypoint wrapper for the PHP-FPM Nextcloud container.
#
# Renders /usr/local/etc/php-fpm.d/zz-pool.conf from the container environment
# at startup so pm.max_children etc. auto-scale with the memory limit (AIO-style
# auto-scaling, but stock images only). PHP-FPM pool files cannot expand
# environment variables natively, so we generate the file here before launching
# php-fpm.
#
# Memory budget model (same rule of thumb the Apache prefork config used):
#   Each busy PHP-FPM child holds ~150 MB (framework + PHP + opcode cache
#   overhead; recalibrate with `pm.max_children` and `docker stats` if needed).
#
# Env (set in compose.yaml from .env):
#   APP_MEM_LIMIT         - container memory limit (e.g. 3G), for a safe default
#   APP_FPM_MAX_CHILDREN  - optional explicit cap; if unset, derived from
#                           APP_MEM_LIMIT as (limit / 150M) rounded down, min 2.
set -euo pipefail

APP_MEM_LIMIT="${APP_MEM_LIMIT:-3G}"
APP_FPM_PM="${APP_FPM_PM:-dynamic}"

# Derive max_children from the memory limit (150 MB per child budget).
derive_children() {
    local lim="$1"
    local mb
    case "$lim" in
        *g|*G) mb=$(( ${lim%[gG]} * 1024 )) ;;
        *m|*M) mb=${lim%[mM]} ;;
        *)     mb=2048 ;;  # fallback
    esac
    local c=$(( mb / 150 ))
    if [ "$c" -lt 2 ]; then c=2; fi
    echo "$c"
}

if [ -z "${APP_FPM_MAX_CHILDREN:-}" ]; then
    APP_FPM_MAX_CHILDREN="$(derive_children "$APP_MEM_LIMIT")"
fi

# Dynamic pool keeps a small warm set and spawns up to max_children only when
# needed (true auto-scaling). Sizing follows the memory limit.
cat > /usr/local/etc/php-fpm.d/zz-pool.conf <<EOF
[www]
user = www-data
group = www-data
; Listen on ALL interfaces so the nginx sidecar can reach us over the Docker
; network (127.0.0.1 would bind only to this container's own loopback -> 502).
listen = 9000
pm = ${APP_FPM_PM}
pm.max_children = ${APP_FPM_MAX_CHILDREN}
pm.start_servers = ${APP_FPM_START_SERVERS:-$(( APP_FPM_MAX_CHILDREN / 4 ))} 
pm.min_spare_servers = ${APP_FPM_MIN_SPARE:-2}
pm.max_spare_servers = ${APP_FPM_MAX_SPARE:-8}
pm.max_requests = 2000
pm.process_idle_timeout = 20s
catch_workers_output = yes
php_admin_value[error_log] = /var/log/php-fpm.log
php_admin_flag[log_errors] = on
EOF

echo "PHP-FPM pool: pm=${APP_FPM_PM} max_children=${APP_FPM_MAX_CHILDREN} (mem_limit=${APP_MEM_LIMIT})"
exec /usr/local/bin/docker-php-entrypoint php-fpm
