<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Networking, TLS and domain options

Decision checklist for a ~400-user deployment: how to expose the stack and which
 domain provider to use.

## Framing: the real decision

The app container serves **plain HTTP on :80**. Public exposure needs **some**
TLS terminator in front (otherwise passwords/tokens cross the internet in cleartext)..
So the question is not "reverse proxy or not" - it is **where TLS is terminated**:

| Terminates TLS | Public port needed | Edge compression/caching | Full-size web uploads |
| --- | --- | --- | --- |
| Caddy (Let's Encrypt) |  ?80 + 443 | Caddy | yes - best |
| Tailscale Funnel | none | Caddy | yes |
| Cloudflare Tunnel | none | Cloudflare + Caddy | ~100MB cap (chunking helps) |
| Tailscale Serve | none | no | yes |
| Raw exposed app port | 8080 + 3478 | no | yes,but NO TLS - private only |

> "Just open the ports" is only acceptable on a private LAN/Tailnet. For 400
> public users it leaks credentials and has no edge caching. Always keep a TLS
> terminator in front.

## Current setup (this repo, unchanged)

- `caddy` publishes **only :80**; TLS is terminated **upstream** by Tailscale
  Funnel.
- The app publishes **no host port** (`container_name` removed so `--scale`
  works)and is reached by Caddy internally.
- `.env` uses plain HTTP values (`OVERWRITEPROTOCOL=http`), correct for the funnel;
  switch to `https` for a direct HTTPS entry point.
- A dedicated `talk` service publishes **3478/tcp + 3478/udp** and proxies its
  signaling backend over `/standalone-signaling`.

## Options and what to change for each

### Option 1 - Caddy :80 + Tailscale Funnel (current; CGNAT / no open ports)

Best when you are behind CGNAT or a NAT you cannot port-forward.

What to change / verify:
- `.env` (set these so browser + desktop/mobile use HTTPS URLs):
  ```bash
  NC_DOMAIN=ck1189.tail650e17.ts.net
  OVERWRITEHOST=ck1189.tail650e17.ts.net
  OVERWRITECLIURL=https://ck1189.tail650e17.ts.net
  OVERWRITEPROTOCOL=https
  NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1 nextcloud ck1189.tail650e17.ts.net
  ```
- On the host, run the funnel: `tailscale funnel --bg http://127.0.0.1:80`
- Keep the current `Caddyfile` (`:80` block,gzip + static caching).

Notes:
- The public URL is a `*.ts.net` name you don't own; if you later get a real
  domain, funnel it via `--https=443` + a CNAME to your `*.ts.net` host.

### Option 2 - Caddy :443 + Let's Encrypt (has public IP or port-forward)

The standard production setup. Real trusted TLS, best large-upload support.

What to change:
- `Caddyfile` - add a site block for the public domain (and/or keep `:80` redirecting to https):
  ```caddy
  nextcloud.example.com {
      encode gzip zstd
      @static path *.css *.js *.svg *.gif *.png *.jpg *.jpeg *.ico *.woff2 *.ttf
      header @static Cache-Control "public, max-age=2592000, immutable"
      reverse_proxy nextcloud-app:80 {
          transport http { response_header_timeout 1h }
      }
      handle_path /standalone-signaling/* { reverse_proxy nextcloud-talk:8081 }
  }
  ```
- `compose.yaml` - publish 443 on caddy:
  ```yaml
  caddy:
    ports:
      - "80:80"
      - "443:443"
  ```
- `.env`:
  ```bash
  NC_DOMAIN=nextcloud.example.com
  OVERWRITEHOST=nextcloud.example.com
  OVERWRITECLIURL=https://nextcloud.example.com
  OVERWRITEPROTOCOL=https
  ```
- Firewall: open/forward **80** and **443**.

Caddy auto-provisions the Let's Encrypt cert. Point your DNS `A` record at the
host IP.

### Option 3 - Cloudflare Tunnel to Caddy (zero open ports + WAF)

Best when you cannot expose any inbound port and want free WAF/DDoS.

What to change:
- Keep `caddy` and the **current** `:80` Caddyfile (Cloudflare forwards HTTP).
- Host the `cloudflared` tunnel on the same host:
  `cloudflared tunnel run --url http://127.0.0.1:80`
  (or a config ingress -> `http://nextcloud-app:80`).
- Use your own domain on Cloudflare (see Domain provider below).
- `.env`:
  ```bash
  NC_DOMAIN=<your-cloudflare-domain>
  OVERWRITECLIURL=https://<your-cloudflare-domain>
  OVERWRITEPROTOCOL=https
  ```
- **Test a max-size web upload before going live** - Cloudflare's free proxy caps
  non-chunked uploads around **100 MB**. Desktop/mobile clients auto-chunk and are
  fine;large web uploads need Nextcloud chunking to work.

### Option 4 - No Caddy: Tailscale Serve / Funnel straight to the app

Simplest, but drops edge compression/caching and Talk routing convenience.

What to change:
- `compose.yaml` - publish 8080 on the app and drop the caddy service:
  ```yaml
  nextcloud-app:
    ports:
      - "8080:80"
  ```
- Tailnet-internal: `tailscale serve --bg http://127.0.0.1:8080`
- Public: `tailscale funnel --bg http://127.0.0.1:8080`
- `.env` same as Option 1 (https values when via Funnel.
- If you use Talk, you must route `/standalone-signaling` yourself (a small Caddy/
  nginx is much easier for this).

### Option 5 - Expose the app port directly + open firewall (private only)

Do **not** do this for public 400 users. Acceptable only on a trusted LAN/VPN.

- `compose.yaml` - publish 8080 on the app, drop caddy.
- Open **8080** (and **3478** for Talk) in the firewall.
- No TLS: works only for a private network with no external exposure.

## Domain provider recommendation

| Provider | Why |
| --- | --- |
| **Cloudflare Registrar + DNS** (recommended) | Registration at cost, free DNS/CDN/WAF, API for Caddy DNS-01 wildcard certs, can switch DNS-only -> Tunnel anytime |
| **Porkbun** | Cheap, friendly, clean DNS UI |
| **Namecheap** | Familiar, cheap |
| **Avoid** (higher fees) | Squarespace (ex-Google), Gandi |

Whichever registrar you register with, point the **DNS** at Cloudflare so you
keep one control plane and an option to use Tunnel later without moving domains.

## Recommended order (for ~400 users)

1. **Caddy :443 + Let's Encrypt, Cloudflare DNS-only** - if you can get a public IP or port-forward. Full-size uploads, real TLS, no third-party buffering.
2. **Caddy :80 + Tailscale Funnel** - your current CGNAT reality;fix `.env` to https (Option 1).
3. **Cloudflare Tunnel -> Caddy** - if you need zero open ports + WAF, after verifying the 100MB web-upload caveat.
4. **No proxy / direct port** - only for internal tailnet use.

## Cloudflare gotcha (read before choosing)

- **Orange cloud (proxy on):** free tier buffers responses and caps non-chunked uploads ~100MB. Safe for Nextcloud if desktop/mobile chunking is used,but verify a large web upload first.
- **Grey cloud (DNS-only):** Cloudflare just resolves the name; your Caddy still does TLS. Best for large uploads. Recommended unless you specifically need the WAF/tunnel.
- To serve big files through the orange cloud reliably, keep the upload limit at 10G only if chunking holds; otherwise consider lowering `upload_max_filesize` (see `config/php-custom.ini`) or enforcing chunked uploads in Nextcloud settings.
