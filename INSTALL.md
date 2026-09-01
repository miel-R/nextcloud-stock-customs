# Nextcloud Stock Docker with Talk and AMI Bot

This repository contains a stock Nextcloud Docker setup with Caddy reverse proxy, including support for Nextcloud Talk and AMI bot.

## Overview

- **Nextcloud**: Latest official image (no 100-user limit)
- **Caddy**: Reverse proxy with automatic TLS/Let's Encrypt
- **Talk**: Video/audio calling support
- **Talk Recording**: Call recording functionality
- **AMI Bot**: Audio Media Interface bot for calls

## Quick Start

### 1. Prerequisites

- Docker and Docker Compose installed
- Ports 80, 443 available on host
- DNS domain pointing to server IP (e.g., nextcloud.local)

### 2. Configure Environment

Create `.env.db` in the repository root:

```
POSTGRES_PASSWORD=nextcloudpass
NC_ADMIN_USER=admin
NC_ADMIN_PASSWORD=admin
NC_DOMAIN=nextcloud.local
```

### 3. Start the Stack

```bash
docker compose up -d
```

### 4. Access Nextcloud

- HTTP: http://localhost:8080
- HTTPS: https://nextcloud.local (via Caddy)

Default login: admin / admin (change immediately!)

### 5. Enable Talk and AMI Bot

Access Nextcloud as admin and:

1. Go to **Settings** → **Apps**
2. Enable **Talk** app
3. Enable **Talk Recording** app (optional)
4. Enable **AMI Bot** app

Or via occ:

```bash
docker compose exec nextcloud occ app:enable talk
docker compose exec nextcloud occ app:enable talk_recording
docker compose exec nextcloud occ app:enable ami_bot
```

### 6. Configure TURN Servers (for Talk)

The Talk container is configured with Google's STUN server. For production, add TURN servers:

```bash
docker compose exec nextcloud occ config:system:set talk_turn_tcp_enabled --value=true --type=bool
docker compose exec nextcloud occ config:system:set talk_turn_udp_enabled --value=true --type=bool
docker compose exec nextcloud occ config:system:set talk_turn_stun_servers --value='["stun.l.google.com:19302","stun1.l.google.com:19302"]' --type=string
```

### 7. Caddy Configuration

The included Caddyfile handles HTTPS. For custom domains:

1. Update `NC_DOMAIN` in `.env.db`
2. Ensure DNS A record points to your server IP
3. Caddy will automatically obtain Let's Encrypt certificates

### 8. Stop/Restart

```bash
docker compose down    # Stop and remove
docker compose up -d   # Start again
```

## Directory Structure

```
Containers/
  talk/           - Talk container (Dockerfile + start.sh)
  talk-recording/ - Talk Recording container
  ami-bot/        - AMI Bot container
Caddyfile         - Caddy reverse proxy config
compose.yaml      - Docker Compose configuration
```

## Ports

| Port | Purpose |
|------|---------|
| 80/443 | Caddy HTTP/HTTPS |
| 8080 | Nextcloud internal (routed via Caddy) |
| 3478 | TURN (TCP/UDP) for Talk |

## Notes

- No 100-user limit like AIO - you control Nextcloud capacity
- Stock Nextcloud image - no AIO-specific constraints
- Caddy handles automatic SSL certificate generation
- All data stored in named Docker volumes
