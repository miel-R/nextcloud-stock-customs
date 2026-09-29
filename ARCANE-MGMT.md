<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Arcane — Modern Docker Management

How to deploy and use **Arcane** (ghcr.io/getarcaneapp/manager) to manage this stack's
Docker Compose projects, containers, volumes, networks, and images from a modern web UI.

> Arcane is a **compose-first** Docker management UI. It discovers Compose projects
> in a projects directory, lets you deploy/redeploy/watch logs, manages images,
> volumes, networks, and includes vulnerability scanning (Trivy) and auto-updates.

---

## TL;DR — deploy (already done)

`ash
# Secrets (already generated and stored in container env)
ENCRYPTION_KEY=49c3ec33803098b139ef9c953767751b
JWT_SECRET=6754c09a444e76d8cb69df3f4b6156d324504885613b0311503f935e9b508716

docker volume create arcane-data

docker run -d \
  --name arcane \
  --restart unless-stopped \
  -p 3552:3552 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v arcane-data:/app/data \
  -e ENCRYPTION_KEY=49c3ec33803098b139ef9c953767751b \
  -e JWT_SECRET=6754c09a444e76d8cb69df3f4b6156d324504885613b0311503f935e9b508716 \
  -e TZ=UTC \
  --cgroupns=host \
  ghcr.io/getarcaneapp/manager:latest
`

**Access:** http://192.1.5.34:3552 (LAN)  
**Health:** curl http://192.1.5.34:3552/api/health → { status:UP}

---

## First login

1. Open http://192.1.5.34:3552
2. Create admin account (email + password ≥ 8 chars)
3. You land on **Environments → Local Docker** → all containers/projects visible

---

## What you can manage

| Area | Capability |
|------|------------|
| **Projects** | Discover Compose files in projects dir, deploy/redeploy/watch logs, build, destroy |
| **Containers** | Start/stop/restart/remove, logs (live), exec shell, inspect, env vars, labels |
| **Images** | Pull, remove, tag, vulnerability scan (Trivy) |
| **Volumes** | Create, inspect, remove, backup, prune unused |
| **Networks** | Create, inspect, remove, ports view, topology graph |
| **Updates** | Image polling, auto-update with dependency labels, ignore per container |
| **Vulnerability scan** | Built-in Trivy scan per image |

---

## Managing this stack's Compose projects

Arcane discovers **Compose projects** in its **Projects Directory** (default /app/data/projects inside the container, mapped to rcane-data volume).

### Add this stack's projects

1. **UI → Environments → Local Docker → Settings → Storage & Limits**
2. Set **Projects Directory** to a host path that contains your compose files, e.g.:
   `
   /home/mis/docker
   `
   (This exposes 
extcloud-stock-customs, mi-nextcloud-talk, etc.)
3. Arcane will scan for compose.yaml, docker-compose.yaml, etc. in subdirectories.

### Or bind-mount the projects dir at deploy

`ash
docker run -d ... \
  -v /home/mis/docker:/app/data/projects:ro \
  ...
`

Then Arcane sees 
extcloud-stock-customs/compose.yaml, mi-nextcloud-talk/docker-compose.yml, etc. as separate projects.

### Project actions

| Action | What it does |
|--------|--------------|
| **Deploy** | docker compose up -d — pulls, (re)creates, starts |
| **Redeploy** | Pull latest images, recreate changed services |
| **Watch logs** | Follows docker compose up output live |
| **Build** | Runs docker compose build (BuildKit) with live progress |
| **Destroy** | docker compose down -v — removes containers, networks, volumes |

---

## Auto-updates (image polling + labels)

Enable in **Environments → Local Docker → Automations → Updates**:

| Label | Effect |
|-------|--------|
| com.getarcaneapp.arcane.updater=true | Enable auto-update for this container |
| com.getarcaneapp.arcane.depends-on=db,redis | Restart order: db/redis first, then this |
| com.getarcaneapp.arcane.updater=false | Disable auto-update (ignore) |

**Example compose.yaml snippet:**

`yaml
services:
  myapp:
    image: ghcr.io/acme/myapp:latest
    labels:
      - com.getarcaneapp.arcane.updater=true
      - com.getarcaneapp.arcane.depends-on=db,redis
      - com.getarcaneapp.arcane.stop-signal=SIGTERM
  db:
    image: postgres:16
  redis:
    image: redis:7
`

---

## Vulnerability scanning (Trivy)

Built-in, free. **Images → Scan** runs Trivy and shows CVEs with severity, fixed version, links.

---

## Socket proxy (optional, more secure)

Instead of mounting /var/run/docker.sock directly, run the **Socket Proxy** (Technology: 	ecnativa/docker-socket-proxy) and point Arcane at it. Limits API surface (e.g., read-only, no exec).

---

## Secrets (keep these safe)

`
ENCRYPTION_KEY=49c3ec33803098b139ef9c953767751b
JWT_SECRET=6754c09a444e76d8cb69df3f4b6156d324504885613b0311503f935e9b508716
`

- ENCRYPTION_KEY: 32 hex chars (16 bytes) — encrypts stored data
- JWT_SECRET: 64 hex chars (32 bytes) — signs auth tokens

Rotate by changing env vars and recreating the container (data in rcane-data volume persists).

---

## Updating Arcane

`ash
docker pull ghcr.io/getarcaneapp/manager:latest
docker compose up -d  # or docker run with same args
`

Data persists in rcane-data volume.

---

## Mobile app (iOS)

TestFlight beta: https://getarcane.app/docs/get-started/mobile — native iOS/iPadOS/macOS app for remote management.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| pi/health not UP | Check docker logs arcane — usually socket permission or cgroup |
| Projects not found | Check Projects Directory in Settings; ensure compose files named correctly |
| Auto-update not working | Check labels on container; check Automations → Updates enabled |
| Vulnerability scan fails | Trivy needs internet to fetch DB; check proxy/firewall |

---

## Security notes

- **/var/run/docker.sock = root on host.** Arcane can start privileged containers, mount host FS. Treat Arcane admin like sudo.
- **LAN binding (port 3552)** — anyone on LAN with access has full Docker control. Put behind Tailscale/VPN or add auth proxy (Authelia, OAuth2-Proxy) if exposed.
- **No RBAC** — all admins are equal. Single-admin homelab is fine; multi-user needs external auth proxy.
- **Encryption keys** — rotate periodically; data in rcane-data is encrypted at rest.

---

## Related docs

- [INSTALL.md](INSTALL.md) — full stack install
- [TALK-BOTS.md](TALK-BOTS.md) — Ami bot install
- [TALK-HPB.md](TALK-HPB.md) — Talk HPB install & register
- [TALK-HPB-RUNBOOK.md](TALK-HPB-RUNBOOK.md) — HPB operations & health check
- [NETWORKING.md](NETWORKING.md) — request paths and DNS

---

## Default admin credentials (first startup)

On first startup, Arcane auto-creates a default admin user. Check the container logs:

`ash
docker logs arcane | grep -A 2 'Default admin user created'
`

**Output:**
`
👑 Default admin user created!
🔑 Password: arcane-admin
⚠️  User will be prompted to change password on first login
`

**Login credentials:**
- **Username:** rcane
- **Password:** rcane-admin
- **Email:** dmin@localhost

You will be prompted to change the password on first login.

To reset and regenerate a new default admin:

`ash
docker stop arcane && docker rm arcane && docker volume rm arcane-data
docker volume create arcane-data
# re-run the docker run command
# check new password: docker logs arcane | grep 'Password:'
`

