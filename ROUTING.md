<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Routing & subdomains

How a browser request travels through this stack, which component does what, and
how to route **multiple subdomains to one host** (e.g. Nextcloud *and* n8n behind
a single reverse proxy edge).

For the two ways the public request can reach this host - Tailscale Funnel, or
open ports straight to Caddy (no Funnel) - see
[Edge options](#edge-options-tailscale-funnel-vs-open-ports-no-funnel).

---

## The request path

```
   browser (type a hostname, e.g. nextcloud.example.com)

        ▼
┌──────────────────── EDGE - choose ONE ──────────────────────┐
│  A) TAILSCALE (Funnel): names the host, terminates TLS,     │
│     forwards decrypted HTTP on :80 to Caddy                 │
│  B) OPEN PORTS (no Funnel): browser goes through your       │
│     router straight to Caddy; Caddy terminates TLS (:443)   │
└──────────────────────────┬──────────────────────────────────┘
                           ▼  (HTTP, still carrying the Host header)
┌──────────────────── CADDY (single edge) ────────────────────┐
│  • entry point into the Docker stack (:80, or :443 when it  │
│    terminates TLS itself for the open-ports case)           │
│  • routes by URL *path*:                                    │
│       /standalone-signaling/*  → nextcloud-signaling:8081   │
│       everything else         → proxy-nginx:80          │
│  • gzip compression + static-asset caching headers          │
└──────────────────────────┬──────────────────────────────────┘
                           ▼
┌──────────────────── NGINX (proxy-nginx) ───────────────┐
│  • serves Nextcloud static files from the shared webroot   │
│  • routes PHP → nextcloud-app:9000 (PHP-FPM)               │
│  • load-balances across many nextcloud-app replicas        │
│  • splits by *hostname* (server_name):                     │
│       nextcloud.example.com → Nextcloud FPM                │
│       n8n.example.com       → n8n_email_summarizer:5678    │
└───────────┬───────────────────────────┬────────────────────┘
            ▼                           ▼
   nextcloud-app:9000 (PHP-FPM)   n8n_email_summarizer:5678
   (Nextcloud)                   (n8n built-in web server)
```

The request keeps its **`Host` header** the whole way; the layer that decides
"which app" looks at that header (or the path) and proxies back out.

---

## What each component does

### Tailscale (Funnel)

- **DNS / hostname** - each machine gets one MagicDNS name
  (`<node>.tailnet.ts.net`). One name per node; **no per-node subdomains**.
- **TLS** - terminates HTTPS at the edge; browsers talk `https://`.
- **Ports** - forwards only **:443 and :80**. Custom ports (like n8n's `:5678`)
  are **not** tunneled - "type a port" won't reach them.
- It does **not** route by hostname or decide which app handles a request; it
  hands decrypted HTTP to Caddy.

### Caddy

- The **single reverse-proxy entry** into the stack, listening on **:80**.
- Routes by **URL path**: `/standalone-signaling/*` → the Talk signaling server;
  everything else → `proxy-nginx`.
- Adds **gzip** and **static caching**.
- Currently a flat `:80` site (does not split by hostname). The hostname split
  lives in nginx (below).

### nginx (`proxy-nginx`)

- The **workhorse for the web tier**.
- Serves **static files** directly from the shared Nextcloud webroot (fast, no
  PHP involved).
- Routes **PHP** to `nextcloud-app:9000` (PHP-FPM pool), and **load-balances**
  across replicas via `upstream php-handler { server nextcloud-app:9000; }`.
- Uses `server_name` to **route by hostname** - the natural place to add a
  second app like n8n on its own subdomain.

---

## The subdomain problem (why one funnel alone is not enough)

Two hard constraints:

1. **No per-node subdomains.** `n8n.<node>.ts.net` does **not** resolve -
   Tailscale MagicDNS only resolves a node's own name (and explicit hostnames
   you add, which map to *nodes*, not sub-domains). Verified: `n8n.ck1189...`
   fails while `ck1189...` resolves.
2. **Funnel only tunnels :80/:443.** You cannot reach n8n by typing a custom
   port through the funnel.

To give a second app (n8n) a working public hostname you need a **real
domain/subdomain that resolves to this host** (see next section). There is no
configuration-only way around it.

---

## DNS setup (registrar e.g. Namecheap / Cloudflare)

Add records so both hostnames resolve to this host. Either individually or with
a wildcard:

```text
A  n8n.example.com       → <this host public IP>
A  nextcloud.example.com → <this host public IP>

# or, to cover any subdomain in one record:
A  *.example.com         → <this host public IP>
```

> This is registrar DNS, not a Docker step. Once the records exist the requests
> reach this host and the reverse proxy (nginx) routes them.

See also `N8N.md` → "Tailscale does NOT create per-node subdomains" for the
reason MagicDNS can't replace this.

---

## Edge options: Tailscale Funnel vs open ports (no Funnel)

How the public request reaches this host depends on whether you use **Tailscale
Funnel** or you **open ports** on your router/firewall directly at Caddy.
Both end the same way: HTTP on `:80` into Caddy, then nginx. Pick one.

| | Tailscale Funnel | Open ports (no Funnel) |
| --- | --- | --- |
| Needs a public IP | No - works behind CGNAT | Yes - you open/forward ports |
| TLS | Tailscale terminates HTTPS | Caddy terminates HTTPS (Let's Encrypt) |
| Ports exposed | :443 and :80 only | :443 + :80 (and :3478 UDP/TCP for TURN) |
| Hostname | Tailscale MagicDNS `<node>.ts.net` | Your own domain → Caddy |
| Setup | `tailscale funnel` on the node | Open ports + Caddy `tls` auto-HTTPS |

### Option E1 - Tailscale Funnel (used in this guide's default)

- Your host has no open inbound ports; Tailscale's servers relay/Funnel public
  traffic to it.
- Exposes the funnel node's hostname; decrypted HTTP reaches Caddy on `:80`.
- **No subdomains** - gets only the one node hostname (see the DNS section for
  getting a second app hostname via your own domain).

### Option E2 - Open ports / direct (no Funnel)

When you **are** port-forwarding (a public IP, or you don't use Tailscale), the
browser goes straight to your router → Caddy:

- **Forward these ports** to this host:
  - `80` (HTTP, redirect/ACME)
  - `443` (HTTPS)
  - `3478` **TCP + UDP** (only if using eturnal TURN for Talk)
  - *(the 16k TURN relay range: only if `compose.turn.yaml` is applied - see
    `INSTALL.md`)*
- **Caddy terminates TLS itself** with Let's Encrypt. Point your domain records
  (`A`/`AAAA`) at this host's **public IP** (see the DNS section), and change the
  Caddy site from `:80` to `:443` with `tls` so it issues certs:

```caddyfile
nextcloud.example.com {
    encode gzip

    handle_path /standalone-signaling/* {
        reverse_proxy nextcloud-signaling:8081
    }
    handle {
        reverse_proxy proxy-nginx:80 { ... }
    }
}

n8n.example.com {
    reverse_proxy n8n-n8n-1:5678 { ... }
}
```

- Run Nextcloud with HTTPS on: set `OVERWRITEPROTOCOL=https` and
  `OVERWRITECLIURL=https://nextcloud.example.com` in `.env`, and add
  `TRUSTED_PROXIES` for nothing extra here if Caddy terminates directly (see
  `NETWORKING.md` for the exact `.env` changes).
- **Port 80 must be free** on this host (stop apache2/nginx that hold `:80`).
- Verify `ss -tlnp | grep -E ':80|:443'`.

> With open ports you own the domain, so subdomain routing works exactly as in
> "The router" below - the only difference is *who* terminates TLS (Caddy
> instead of Tailscale).

See `NETWORKING.md` for the full comparison (Caddy :443 + Let's Encrypt vs
Tailscale Funnel vs Cloudflare Tunnel).

---

## The router: one shared nginx for both apps

The recommended layout (Option A) is a **single shared nginx** that fronts both
Nextcloud and n8n, routing by `Host` header. n8n needs **no nginx of its own** -
its image ships a built-in web server; nginx just reverse-proxies it.

### 1. `config/nginx.conf` - add a second `server` block for n8n

Add beside the existing `server { server_name _; ... }` (the closed default):

```nginx
# n8n on its own hostname - keep n8n at its OWN root (subpath hosting is broken)
server {
    listen 80;
    server_name n8n.example.com;                # your real n8n subdomain

    client_max_body_size 20m;                   # smaller than Nextcloud's 2G uploads

    location / {
        proxy_pass         http://n8n_email_summarizer:5678;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        # WebSocket support (n8n editor push):
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 3600s;
    }
}
```

nginx then chooses by `server_name`: `nextcloud.example.com` falls through to the
default Nextcloud block, `n8n.example.com` goes to n8n.

### 2. `compose.n8n.yaml` - proxied mode

- **Comment out** the `ports: "127.0.0.1:5678:5678"` line so n8n is reachable
  only on `nt_n8n_network` (by nginx), not published on the host.
- Set the public-URL vars from `.env` so n8n emits correct links:
  `N8N_HOST=n8n.example.com`, `N8N_PROTOCOL=https`, `N8N_PORT=5678`.
- n8n already joins `nt_n8n_network`, so `nginx` reaches it as
  `n8n_email_summarizer:5678`. No additional nginx container is added to the
  n8n stack.

### 3. `Caddyfile` / `compose.yaml` - no change

Caddy already forwards **every** hostname on `:80` to `proxy-nginx:80`
(and the Talk signaling path separately). nginx then performs the hostname
split. Single edge: `Funnel → Caddy → nginx → {Nextcloud | n8n}`.

### 4. `.env`

Add the n8n hostname and exposure vars:

```bash
N8N_DOMAIN=n8n.example.com
N8N_HOST=n8n.example.com
N8N_PROTOCOL=https
N8N_PORT=5678
```

> `N8N_DOMAIN` is what Caddy would use if routing in Caddy instead (Option B,
> below). When routing in nginx, nginx's `server_name` uses the same value.

---

## Choosing where to split by hostname

Two valid placements; pick one so you do not maintain both:

| Option | Split by hostname in | When to use |
| --- | --- | --- |
| **A (recommended)** | **nginx** (`config/nginx.conf` `server_name`) | One shared nginx fronts both apps; single config surface, fewest edges |
| **B** | **Caddy** (`Caddyfile` routed block) | You prefer to keep nginx Nextcloud-only and add n8n routing at the edge |

Both need the same DNS record + n8n proxied mode. **Prefer A** for fewer moving
parts and because nginx already owns Nextcloud host routing.

> n8n **must** be served at its own root (a real hostname), not a subpath like
> `/n8n/` - subpath hosting is broken in current n8n
> (n8n-io/n8n#19635).

---

## Notes & troubleshooting

- **nginx is not the 100+ user bottleneck.** Nextcloud capacity is limited by
  the PHP-FPM tier, not nginx. One nginx comfortably fronts many users / many
  `nextcloud-app` replicas (`docker compose up -d --scale nextcloud-app=N`). You
  **do not scale nginx**; keep it a singleton.
- **Wildcard DNS caveats** - `*.example.com` sends *every* subdomain to this
  host; only use it when you control the whole domain and want a catch-all.
- **Placeholder hostnames** - the examples use `n8n.example.com`; replace with
  your real subdomain before it will resolve.
- **`password authentication failed for user "n8n"`** means the n8n role/db
  were never created on an existing `nextcloud_db` volume - see `N8N.md`
  section 1 / 1b.

---

## See also

- `N8N.md` - the n8n integration, its own `n8n_stack` project, the toggle
  (`N8N_INSTALL` / `COMPOSE_PROFILES`), and Tailscale subdomain limitations.
- `NETWORKING.md` - TLS / domain provider comparison (Caddy Let's Encrypt,
  Tailscale Funnel, Cloudflare).
- `INSTALL.md` - full stock install runbook.