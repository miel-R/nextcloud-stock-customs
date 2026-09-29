<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Portainer CE - managing this stack with a GUI

How to deploy **Portainer CE** on the same host so you can manage the Nextcloud Talk stack
(containers, volumes, networks, logs, console) from a web UI instead of the CLI.

> This document assumes the same host that runs 
extcloud-stock-customs.
> Portainer is deployed **on the host Docker daemon** and therefore sees every
> project (
extcloud-stack, db-services, 
8n_stack, mi-nextcloud-talk).
> It does **not** run inside any of the compose files - it manages them from the
> outside.

---

## TL;DR - one command

`ash
docker volume create portainer_data

docker run -d \
  --name portainer \
  --restart always \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
`

Open https://<host-ip>:9443 → create admin user (password **12+ chars**) →
select **Local** environment → done.

---

## Why Portainer here?

- You already run multiple compose projects (compose.yaml, compose.db.yaml,
  compose.n8n.yaml, plus the Ami bot repo). Portainer shows them all in one
  place.
- One-click **restart / recreate / logs / console** for any container.
- Visual **volumes / networks** view - useful for the shared 
t_n8n_network
  and the 
extcloud_www volume.
- No extra dependencies; single container, ~30 MB image.

---

## Secure-by-default deployment (loopback only)

The stack already uses Tailscale Funnel for public HTTPS. Portainer does **not**
need to be public. Bind it to 127.0.0.1 and reach it over an SSH tunnel:

`ash
docker volume create portainer_data

docker run -d \
  --name portainer \
  --restart always \
  -p 127.0.0.1:9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
`

Then from your workstation:

`ash
ssh -L 9443:127.0.0.1:9443 <user>@<host>
`

Open https://localhost:9443 in your browser. No public exposure, no cert
management (Portainer generates a self-signed cert on first start; accept it in
the browser).

---

## LAN-only deployment (no tunnel)

If you want direct LAN access without a tunnel, bind to all interfaces:

`ash
docker run -d \
  --name portainer \
  --restart always \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
`

Then open https://<host-lan-ip>:9443.

> **Warning:** Anyone who reaches Portainer on the LAN has full control of the
> Docker daemon (root-equivalent). Only do this on a trusted, isolated network.
> The stack's public services already sit behind Tailscale Funnel; adding
> Portainer to the same public surface is unnecessary risk.

---

## Compose file (alternative to docker run)

If you prefer declaring it in a compose file alongside the stack (but **not**
inside compose.yaml - it manages the host, not the project):

`ash
# /home/mis/docker/portainer/docker-compose.yml
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      -  127.0.0.1:9443:9443     # loopback only (tunnel)
      # - 9443:9443             # LAN (see warning above)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data

volumes:
  portainer_data:
`

`ash
cd /home/mis/docker/portainer
docker compose up -d
`

---

## First-time setup

1. Open the URL (https://localhost:9443 via tunnel, or https://<ip>:9443).
2. Browser warns about self-signed cert → **Advanced → Proceed**.
3. Create an admin user:
   - **Username:** whatever you like
   - **Password:** **12 characters minimum** (Portainer enforces this)
4. **Environment** → select **Local** → **Connect**.
5. You land on **Home → Local** → **Containers**. All projects are visible.

---

## What you will see

| Portainer section | What it shows for this stack |
|-------------------|------------------------------|
| **Containers** | 
extcloud-caddy, 
extcloud-signaling, 
extcloud-turn, 
extcloud-cron, 
extcloud-stack-nextcloud-app-1, proxy-nginx, postgres-db, 
extcloud-redis, 
8n_email_summarizer, mi-talk-bot (if running) |
| **Volumes** | 
extcloud_www, 
extcloud_caddy_data, 
extcloud_redis_data, postgres_data, 
8n_data, portainer_data, mi_talk_bot_data |
| **Networks** | 
t_n8n_network (shared), 
8n_stack_n8n_network, mi-nextcloud-talk_default |
| **Stacks** | Not auto-populated (Portainer Stacks = its own compose deployments). Your existing CLI compose projects appear under **Containers** grouped by label com.docker.compose.project. |

---

## Common operations

| Task | Portainer UI |
|------|--------------|
| Restart a service | Containers → tick box → **Restart** |
| Recreate with new .env / image | Containers → tick → **Recreate** → **Pull latest image** → **Start** |
| View live logs | Click container name → **Logs** (follow toggle) |
| Open shell | Click container name → **Console** → ash / sh |
| Inspect env vars | Container → **Details** → **Env** |
| Prune unused volumes | Volumes → **Remove unused** (careful: 
extcloud_www is named, not anonymous) |

---

## Managing the Ami Talk bot

The Ami bot lives in a **separate repo** (/home/mis/docker/ami-nextcloud-talk).
Portainer will see its container (mi-talk-bot) because it runs on the same
Docker daemon. You can restart/recreate it from the UI, but its compose file
is not a Portainer Stack unless you import it.

To import it as a Stack:

1. **Stacks → Add stack** → **Web editor**
2. Name: mi-nextcloud-talk
3. Paste the contents of /home/mis/docker/ami-nextcloud-talk/docker-compose.yml
4. **Deploy the stack**

Now it appears under **Stacks** and you can Up / Down / Pull / Redeploy
from the UI.

---

## Updating Portainer

`ash
docker stop portainer
docker rm portainer
docker pull portainer/portainer-ce:latest
# re-run the same docker run / docker compose up -d command
`

Data persists in portainer_data volume.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| docker: Error response from daemon: conflict... port is already allocated | Another process on 9443. ss -ltnp | grep 9443 → kill or change port. |
| Browser shows Your connection is not private | Expected - Portainer uses a self-signed cert. Click **Advanced → Proceed**. |
| Permission denied on /var/run/docker.sock | The Portainer container must run as root (default). Do not add :ro or user mapping. |
| Containers from other projects missing | Portainer only sees the Docker daemon it mounts. If you run rootless Docker or a remote daemon, point Portainer at that socket / API endpoint instead. |
| Forgot admin password | docker logs portainer shows the generated one on first run. If you changed it, delete portainer_data volume and recreate (loses settings). |

---

## Security notes (read once)

- **/var/run/docker.sock = root on the host.** Portainer can start privileged
  containers, mount the host filesystem, and escape to the host. Treat the
  Portainer admin account like sudo.
- **Do not expose Portainer publicly.** The tunnel method keeps it off the
  internet. If you must expose it, put it behind an additional auth layer
  (Authelia, OAuth2-Proxy, Tailscale Serve) and enforce MFA.
- **Portainer CE has no RBAC.** All admins are equal. For teams, Portainer
  Business Edition adds roles / LDAP / OIDC.
- **Keep it updated.** docker pull portainer/portainer-ce:latest monthly.

---

## Related docs

- [INSTALL.md](INSTALL.md) - full stack install
- [TALK-BOTS.md](TALK-BOTS.md) - Ami bot install
- [TALK-HPB.md](TALK-HPB.md) - Talk HPB install & register
- [TALK-HPB-RUNBOOK.md](TALK-HPB-RUNBOOK.md) - HPB operations & health check
- [NETWORKING.md](NETWORKING.md) - request paths and DNS
