<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Rancher - managing this stack with Rancher

How to use **Rancher** to manage the Nextcloud Talk stack (containers, volumes, networks)
deployed via Docker Compose on this host.

> Rancher is primarily a **Kubernetes** management platform. It can also manage
> standalone Docker hosts via the  Docker node driver, but the experience is
> less integrated than Portainer for pure Docker Compose workloads. This doc
> covers the practical path: importing the existing Docker host into Rancher
> so you get a UI for containers / logs / shell without migrating to K8s.

---

## TL;DR - Rancher on the same host (quick test)

`ash
# 1) Rancher server (single container, self-signed cert)
docker run -d --restart=unless-stopped \
  -p 80:80 -p 443:443 \
  --privileged \
  rancher/rancher:latest

# 2) Open https://<host-ip> → accept cert → set admin password →
#    Skip for now (no K8s cluster yet) → Local cluster
`

This gives you a Rancher UI that manages the **local Docker daemon** as a
Custom cluster. You can see all containers from 
extcloud-stack,
db-services, 
8n_stack, mi-nextcloud-talk in one place.

---

## Why Rancher here?

| Reason | Notes |
|--------|-------|
| Single pane for multiple compose projects | 
extcloud-stack, db-services, 
8n_stack, mi-nextcloud-talk |
| Kubernetes path later | If you migrate Talk/Nextcloud to K8s (Helm charts exist), Rancher is already there |
| RBAC, audit, OIDC | Rancher has built-in SSO (GitHub, Azure AD, Keycloak, etc.) |
| Fleet / continuous delivery | Can sync Git repos to clusters (including Docker Compose via kompose or native) |

> **Caveat:** For *only* Docker Compose management on one host, **Portainer CE is
> lighter, faster, and purpose-built**. Rancher adds ~500 MB RAM and a full
> K8s control plane (even for Docker-only mode). Use Rancher if you *plan*
> to run K8s workloads; otherwise Portainer is the pragmatic choice.

---

## Architecture: where Rancher fits

`
┌─────────────────────────────────────────────────────────────────┐
│                        HOST (Linux)                             │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Rancher Server (container)                              │   │
│  │  - UI on :80/:443                                        │   │
│  │  - Embedded k3s (local cluster)                          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                 │
│                              │ manages via Docker socket       │
│                              ▼                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Docker Daemon (host)                                    │   │
│  │  ├─ compose project: nextcloud-stack                     │   │
│  │  ├─ compose project: db-services                         │   │
│  │  ├─ compose project: n8n_stack                           │   │
│  │  └─ compose project: ami-nextcloud-talk (separate repo)  │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
`

Rancher imports the host as a **Custom cluster** (type: docker). It talks to
the host Docker socket and surfaces containers, images, volumes, networks.

---

## Install options

### Option A: All-in-one on the same host (quickest)

`ash
# Rancher needs privileged for the embedded k3s
docker run -d --restart=unless-stopped \
  --name rancher \
  -p 80:80 -p 443:443 \
  --privileged \
  -v rancher_data:/var/lib/rancher \
  rancher/rancher:latest
`

- UI: https://<host-ip> (self-signed cert, accept in browser)
- First boot: set admin password → **Skip for now** (no downstream clusters)
- You land in the **local** cluster → **Cluster Management → local** → **Workloads**

> **Port conflict:** This stack's Caddy already binds host 80 and 443. You
> **cannot** run Rancher on the same ports. Choose one:
>
> - Move Rancher to different ports (-p 8080:80 -p 8443:443) and proxy via
>   Caddy (add a site block), OR
> - Run Rancher on a **different host / VM** (recommended for production).

### Option B: Rancher on a separate management host (recommended)

Run Rancher on a small VM (2 vCPU, 4 GB RAM) dedicated to management. Then
**import this host** as a Docker node:

1. On the management VM:
   `ash
   docker run -d --restart=unless-stopped -p 80:80 -p 443:443 \
     --privileged -v rancher_data:/var/lib/rancher rancher/rancher:latest
   `
2. In Rancher UI: **Cluster Management → Create → Custom → Docker**
3. Copy the generated docker run command (it contains a token) and run it
   **on this Nextcloud host**:
   `ash
   # example (token differs each time)
   docker run -d --privileged --restart=unless-stopped \
     --net=host -v /etc/kubernetes:/etc/kubernetes -v /var/run:/var/run \
     rancher/rancher-agent:v2.x.x --server https://<rancher-url> --token <token> --ca-checksum <checksum> --etcd --controlplane --worker
   `
   (For Docker-only, you can omit --etcd --controlplane --worker and use the
   simpler **Import Docker** command Rancher gives you.)

This keeps ports 80/443 free for Caddy on the Nextcloud host.

### Option C: Rancher Desktop (local development only)

If you develop on Windows/Mac/Linux and want a local Kubernetes + Docker
environment that mirrors the stack:

1. Install **Rancher Desktop** (rancherdesktop.io) — it ships dockerd,
   kubectl, helm, k3s inside a VM.
2. Enable **Dockerd (moby)** in Settings → Kubernetes → Container Runtime.
3. Point your CLI at docker context use rancher-desktop.
3. Compose up this repo — runs locally, same images.

This is for *dev*, not for the production host.

---

## First-time setup (Option A)

1. Open https://<host-ip> → **Advanced → Proceed** (self-signed cert).
2. Set **admin password** (min 12 chars).
3. **Cluster Setup** → **Skip for now** (creates local cluster managing the
   host Docker).
3. **Cluster Management → local** → you see all containers.

### What you get out of the box

| Rancher section | Maps to |
|-----------------|---------|
| **Workloads → Deployments/DaemonSets** | (empty — no K8s workloads yet) |
| **Service Discovery → Services** | (empty) |
| **Resources → Containers** | **All Docker containers** from every compose project |
| **Resources → Images** | Local Docker images |
| **Storage → PersistentVolumes** | (K8s PVs only — not Docker volumes) |
| **Storage → Docker Volumes** | Docker named volumes (
extcloud_www, portainer_data, etc.) |
| **Networking → Docker Networks** | 
t_n8n_network, 
8n_stack_n8n_network, etc. |

> **Key limitation:** Rancher's Docker view is read-heavy. You can **restart**,
> **exec (shell)**, **view logs**, **inspect** — but **recreate with new env**
> or **scale** a compose service is not native. For that, you still docker
> compose up -d on the host, or use Rancher's **Fleet** to sync a Git repo
> that renders to Docker Compose via kompose.

---

## Managing this stack from Rancher

### Restart a container

**Resources → Containers** → filter by name (
extcloud-signaling) →
**⋮ → Restart**.

### Shell into a container

**Resources → Containers** → click name → **Execute Shell** → ash.

### View live logs

**Resources → Containers** → click name → **Logs** (toggle **Follow**).

### Inspect environment / labels

**Resources → Containers** → click name → **Env Vars** / **Labels**.
Labels include com.docker.compose.project, com.docker.compose.service.

### Recreate with new image / env (the compose way)

Rancher does not drive docker compose directly. Two paths:

1. **CLI on host** (unchanged):
   `ash
   cd /home/mis/docker/nextcloud-stock-customs
   docker compose up -d --force-recreate signaling
   `

2. **Rancher Fleet (GitOps)** — push a Git repo with the compose file, Rancher
   applies it via kompose → K8s resources. Overkill for one host.

### Import the Ami bot repo as a Fleet repo

If you want Rancher to manage the Ami bot compose file:

1. Push /home/mis/docker/ami-nextcloud-talk to a Git repo (GitHub/Gitea).
2. **Continuous Delivery → Fleet → Repositories → Create** → point at that repo.
3. Fleet clones it, runs kompose convert on docker-compose.yml, deploys the
   resulting K8s manifests to the local cluster.

> This converts Docker Compose → K8s. The bot then runs as a Pod, not a plain
> container. Networking changes (no more host.docker.internal style access).

---

## TLS / certificates

Rancher generates a self-signed cert on first boot. For a real cert:

1. **Let's Encrypt (HTTP-01):** Rancher can request certs if port 80 is free.
   But Caddy owns 80/443 on this host → conflict.
2. **DNS-01 (recommended):** Add a DNS provider (Cloudflare, Route53, etc.) in
   Rancher → **Cluster Management → local → Edit → Advanced → Cert Manager**,
   and Rancher will issue wildcard certs for *.<your-domain>.

If you run Rancher on a separate management VM (Option B), ports 80/443 are
free and HTTP-01 works automatically.

---

## Security notes

| Risk | Mitigation |
|------|------------|
| **--privileged + /var/run/docker.sock** = root on host | Rancher container *is* root-equivalent. Treat the Rancher admin account like sudo. |
| **No RBAC in Rancher CE?** Rancher CE **has** RBAC (projects, roles, OIDC). Portainer CE does not. | Use projects to isolate teams if multiple people access Rancher. |
| **Rancher UI exposed publicly** | Put it behind Tailscale Funnel / VPN / OAuth2-Proxy. Do not leave :443 open to the internet with only a password. |
| **Embedded k3s etcd** stores cluster state in ancher_data volume | Back up that volume (/var/lib/rancher). Losing it = losing all downstream cluster registrations. |

---

## Updating Rancher

`ash
docker stop rancher
docker rm rancher
docker pull rancher/rancher:latest
# re-run the same docker run command (data persists in rancher_data volume)
`

---

## Uninstall (clean)

`ash
docker stop rancher
docker rm rancher
docker volume rm rancher_data
# removes everything Rancher created
`

---

## Decision: Rancher vs Portainer for this stack

| Factor | Rancher | Portainer CE |
|--------|---------|--------------|
| **Primary focus** | Kubernetes | Docker / Swarm |
| **Docker Compose management** | Via kompose → K8s (indirect) | Native |
| **RAM on host** | ~500 MB (k3s + UI) | ~50 MB |
| **RBAC / SSO** | Built-in (CE) | Business only |
| **GitOps (Fleet)** | Yes, native | No |
| **Learning curve** | Steeper | Flat |
| **Recommended if** | You will run K8s workloads | Pure Docker Compose, single host |

**For this repo today:** Portainer is the pragmatic tool. Rancher adds
complexity without benefit *unless* you are already standardizing on Rancher
for Kubernetes across your infra. The PORTAINER.md doc remains the
recommended path; this RANCHER.md exists for teams that have mandated
Rancher as their platform.

---

## Related docs

- [INSTALL.md](INSTALL.md) - full stack install
- [TALK-BOTS.md](TALK-BOTS.md) - Ami bot install
- [TALK-HPB.md](TALK-HPB.md) - Talk HPB install & register
- [TALK-HPB-RUNBOOK.md](TALK-HPB-RUNBOOK.md) - HPB operations & health check
- [NETWORKING.md](NETWORKING.md) - request paths and DNS
