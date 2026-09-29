<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Talk HPB - operations runbook

Operating and troubleshooting the Nextcloud Talk **High-performance backend**
(HPB) on this stack: how to restart it, how to tell whether it is healthy, and
how to find the cause when it is not.

Companion documents: [TALK-HPB.md](TALK-HPB.md) (install and register),
[ROUTING.md](ROUTING.md) (the full request path), [RECOVERY_AFTER_INTERNET_RESTART.md](RECOVERY_AFTER_INTERNET_RESTART.md).

---

## TL;DR quick card

```bash
cd /home/mis/docker/nextcloud-stock-customs

# is it healthy?  (read-only, prints PASS/FAIL per check, exit 1 if broken)
bash config/talk-hpb-check.sh

# restart the thing you changed
docker compose restart caddy        # after editing the Caddyfile
docker compose up -d                # after editing .env or compose.yaml

# re-register the HPB (add does NOT overwrite - always delete first)
docker compose exec -T nextcloud-app php occ talk:signaling:delete \
  "wss://<NC_DOMAIN>/standalone-signaling"
docker compose exec -T nextcloud-app php occ talk:signaling:add \
  "wss://<NC_DOMAIN>/standalone-signaling" <SIGNALING_SECRET>
```

**One-line decision rule:** the HPB is a *signaling server behind a reverse
proxy*. It is working when Caddy answers on **three** ports (80, 443, 8444),
the public domain resolves **inside the containers** to Caddy's fixed IP, and
`https://<NC_DOMAIN>/standalone-signaling/api/v1/welcome` returns JSON. Anything
else is one of the failures in [section 5](#5-troubleshooting).

---

## 1. What the HPB is, and the three request paths

The HPB is a separate service (`strukturag/nextcloud-spreed-signaling`) that
holds WebSocket connections and fans out events. It is **not** part of
Nextcloud - which is why it can be broken while Nextcloud itself looks perfect.

Three independent request paths have to work. Most HPB problems are exactly one
of them, so identifying the broken path is 90% of the debugging.

```
                        Tailscale Funnel
                        (public TLS, 100.x:443)
                               |
                               v  Host: <NC_DOMAIN>
                      +-------------------+
   browser  --wss-->  |  Caddy  :80      | --> proxy-nginx:80 --> nextcloud-app
   (WS + calls)       +-------------------+        (normal web)
                               ^
                               |  (containers resolve <NC_DOMAIN> to 172.18.0.250
                               |   via extra_hosts - Funnel is NOT reachable
                               |   from inside the containers)
   nextcloud-app ------+
   nextcloud-cron      |  +-------------------+
   (back-channel       +->|  Caddy  :443      | --> signaling:8081
    notifications,        |  (tls internal)   |     (path 2)
    admin setup check)    +-------------------+
                               ^
   nextcloud-signaling -----+   (Spreed-Signaling-Backend, capabilities)
        (path 3)        |  +-------------------+
                         +->|  Caddy  :8444     | --> proxy-nginx:80 --> nextcloud-app
                            |  (tls internal)   |     (path 3, by container name)
                            +-------------------+
```

| # | Path | From → To | Why it breaks |
| --- | --- | --- | --- |
| 1 | **WebSocket** | browser → Caddy `:80` → signaling:8081 | Caddy path matcher does not match the bare `/standalone-signaling` |
| 2 | **Back-channel** | app/cron → Caddy `:443` → signaling:8081 | Nothing listening on 443; URL is hardcoded to `https://` by spreed |
| 3 | **Backend** | signaling → Caddy `:443`/`:8444` → Nextcloud OCS API | Wrong `SIGNALING_BACKEND_URL`, or Caddy missing the 8444 listener |

Two facts cause most of the confusion and are worth internalising:

- **The back-channel URL is not configurable.** spreed derives it from the
  registered `wss://` server URL and hardcodes the scheme and port
  (`Signaling\BackendNotifier::backendRequest` and
  `Signaling\Manager::checkServerCompatibility` both do
  `$url = 'https://' . substr($url, 6);`). So it is *always*
  `https://<NC_DOMAIN>/standalone-signaling/...` on port 443. Talk 24 has no
  `--interface` option to point it somewhere else.
- **The containers cannot reach the public URL.** Tailscale Funnel does not
  hairpin and the containers have no route to `100.64.0.0/10`; cURL from inside
  a container to the public name just times out (curl error 28). That is why
  `compose.yaml` pins the public domain to Caddy's container IP via
  `extra_hosts`. The pin is only useful if something *answers* there - hence
  the internal `:443` listener.

---

## 2. Known-good baseline

These values must agree with each other. `.env` is the single source of truth;
nothing here should be hardcoded anywhere else.

| Value | Where | Live value on mis-server |
| --- | --- | --- |
| `NC_DOMAIN` | `.env` | `mis-server.tail204a2d.ts.net` |
| `CADDY_INTERNAL_IP` | `.env` | `172.18.0.250` (must match `ipv4_address` in `compose.yaml`) |
| `SIGNALING_BACKEND_PORT` | `.env` | `8444` (Caddy listener the signaling server uses) |
| `SKIP_VERIFY` | `.env` | `true` (signaling → Caddy's self-signed cert) |
| `SIGNALING_BACKEND_URL` | `.env` | `https://mis-server.tail204a2d.ts.net,https://nextcloud-caddy:8444` |
| registered HPB | Nextcloud DB | `wss://mis-server.tail204a2d.ts.net/standalone-signaling` with **`verify: false`** |
| secrets | `.env` | `SIGNALING_SECRET` = `INTERNAL_SECRET` = `TURN_SECRET` (all three equal) |

Caddy listener map:

| Port | Bound to host? | Purpose | Cert |
| --- | --- | --- | --- |
| `80` | yes (`0.0.0.0:80`) | public site, target of Tailscale Funnel | none (plain HTTP) |
| `443` | **no** (container-internal) | back-channel from the app/cron containers | `tls internal`, self-signed |
| `8444` | **no** (container-internal) | signaling → Nextcloud OCS API by container name | `tls internal`, self-signed |

The signaling container listens on `0.0.0.0:8081` and is **not** published - it
is only reachable through Caddy. That is intentional: the browser must go
through Caddy so the TLS/SNI and the path are correct.

---

## 3. Restarting

All commands assume you are in the repo directory:

```bash
cd /home/mis/docker/nextcloud-stock-customs
```

### 3.0 The three compose projects

This is the single most common source of confusion. There is **no** one
`docker compose up -d` that brings up everything:

| Project name | Compose file | Containers |
| --- | --- | --- |
| `nextcloud-stack` | `compose.yaml` | `nextcloud-caddy`, `nextcloud-signaling`, `nextcloud-turn`, `nextcloud-cron`, `nextcloud-app` |
| `db-services` | `compose.db.yaml` | `proxy-nginx`, `postgres-db`, `nextcloud-redis` |
| `n8n_stack` | `compose.n8n.yaml` | `n8n_email_summarizer` |
| `ami-nextcloud-talk` | separate repo `~/docker/ami-nextcloud-talk` | `ami-talk-bot` |

Compose `depends_on` only works **within** one project. `nextcloud-stack` does
not know that Caddy needs `proxy-nginx` from `db-services`. If you start
`nextcloud-stack` while `db-services` is down, Caddy comes up fine and every
page returns **502**. Start `db-services` first.

### 3.1 Full stack, in the right order

```bash
cd /home/mis/docker/nextcloud-stock-customs

docker compose -f compose.db.yaml up -d          # 1. postgres, redis, nginx
docker compose -f compose.yaml up -d             # 2. app, cron, caddy, signaling, turn
docker compose -f compose.n8n.yaml up -d         # 3. n8n (optional)

# if the talk bot matters too:
docker compose -f ~/docker/ami-nextcloud-talk/docker-compose.yml up -d
```

Wait for health, then verify:

```bash
docker compose ps
bash config/talk-hpb-check.sh
```

`postgres-db`, `nextcloud-redis` and `proxy-nginx` are **singletons** - never
`--scale` them (see [SCALING.md](SCALING.md)).

### 3.2 Restart a single container

```bash
docker compose restart signaling      # the HPB itself
docker compose restart caddy          # the reverse proxy
docker compose restart nextcloud-cron
```

`nextcloud-app` has no fixed container name (it is designed to be scalable), so
restart the *service*, which resolves the real container name for you:

```bash
docker compose restart nextcloud-app
```

`docker compose restart` only bounces the process. Use `up -d` instead when you
changed `compose.yaml` or `.env` - that recreates the container so it picks up
the new configuration.

### 3.3 After editing the Caddyfile

The Caddyfile is bind-mounted read-only from the repo, but **Caddy is
configured with `admin off`, so there is no hot reload** - a `docker compose
restart` is the only way to apply a change. Validate first, then restart:

```bash
cd /home/mis/docker/nextcloud-stock-customs

# 1. validate (never restart a container onto a config that does not parse)
docker run --rm \
  -e NC_DOMAIN="$(grep -E '^NC_DOMAIN=' .env | cut -d= -f2-)" \
  -e N8N_DOMAIN="$(grep -E '^N8N_DOMAIN=' .env | cut -d= -f2-)" \
  -e SIGNALING_BACKEND_PORT="$(grep -E '^SIGNALING_BACKEND_PORT=' .env | cut -d= -f2- || echo 8444)" \
  -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# 2. only if that printed "Valid configuration"
docker compose restart caddy
sleep 5
docker logs --tail 20 nextcloud-caddy
```

The `-e` flags matter: `{$NC_DOMAIN}` and friends are environment variables, and
without them Caddy validates a *different* config than the one it will run.

Check the Caddyfile for CRLF before deploying. A Windows editor that saves with
`CRLF` produces a file Caddy may reject or silently mis-parse. Convert with:

```bash
sed -i 's/\r$//' Caddyfile
```

Restarting Caddy costs a few seconds of downtime for the whole site. There is no
zero-downtime option here (single Caddy container, `admin off`). Prefer
editing during a quiet moment.

### 3.4 After editing `.env` or `compose.yaml`

```bash
cd /home/mis/docker/nextcloud-stock-customs
docker compose config -q          # required: catches bad interpolation
docker compose up -d              # recreates containers, applies new env
```

`docker compose up -d` only recreates services whose config actually changed, so
it is safe to run any time.

### 3.5 After a reboot or an internet outage

Everything is `restart: unless-stopped`, so containers come back on their own.
What does **not** come back on its own is the part that breaks: if the Docker
network is recreated, Caddy may land on a different IP than
`CADDY_INTERNAL_IP`, and the `extra_hosts` pin then points containers at an
address nothing is listening on.

```bash
cd /home/mis/docker/nextcloud-stock-customs

docker compose -f compose.db.yaml up -d
docker compose -f compose.yaml up -d

# confirm the pin and the listeners agree
bash config/talk-hpb-check.sh

# Funnel must be back on (it does not survive a reboot by itself)
tailscale funnel status
#   if a port is missing, re-enable it - check the exact flags with
#   `tailscale funnel --help`; the live config proxies
#     https://<NC_DOMAIN>       -> http://127.0.0.1:80    (Nextcloud)
#     https://<NC_DOMAIN>:8443  -> http://127.0.0.1:5679  (n8n)
```

More in [RECOVERY_AFTER_INTERNET_RESTART.md](RECOVERY_AFTER_INTERNET_RESTART.md).

### 3.6 What not to do

| Do not | Why |
| --- | --- |
| `docker compose down -v` | `-v` deletes the `nextcloud_www` volume: the entire Nextcloud webroot is gone. Plain `down` (no `-v`) is safe - volumes are named, not anonymous. |
| `docker compose up -d --scale proxy-nginx=2` | `proxy-nginx` is a singleton. Two nginx containers behind one Caddy upstream is not supported here. |
| Add a second `talk:signaling:add` | `add` does not overwrite; it appends. Talk 24 warns that multiple HPBs are deprecated. Always `delete` first. |
| Delete the `caddy_data` volume | It holds the internal CA and the issued `tls internal` certificate. Losing it forces Caddy to mint a new one - harmless for the containers (they skip verification) but noisy. |
| Trust the internal cert in a browser | Browsers never see it. Funnel terminates TLS with the public certificate before Caddy sees the connection. Do not "fix" this by adding a CA to a client. |

---

## 4. Health check

```bash
cd /home/mis/docker/nextcloud-stock-customs
bash config/talk-hpb-check.sh
```

Read-only, safe to run any time, exits `1` if anything failed so it can be
wired into a monitor. It checks, in order: containers running, Caddy's three
listeners, the `extra_hosts` pin, the back-channel welcome endpoint, the path
matcher on both sites, the public site, signaling's capability fetches, the
`occ` registration, and TURN's published ports.

Green looks like this:

```
1. Caddy listeners (admin API is off, so a restart is the only reload)
  PASS  Caddy listening on :80
  PASS  Caddy listening on :443
  PASS  Caddy listening on :8444
...
result
  All checks passed.
```

The single most useful one-liner when you suspect the HPB:

```bash
docker exec nextcloud-cron curl -sSk -m 10 \
  https://<NC_DOMAIN>/standalone-signaling/api/v1/welcome
```

Healthy output: `{"nextcloud-spreed-signaling":"Welcome","version":"2.1.1~docker"}`.
This is byte-for-byte the URL Nextcloud's own admin setup check calls, so if it
works, that check works.

---

## 5. Troubleshooting

### 5.1 Which path is broken?

Start from the symptom, then confirm with the two commands that separate the
three paths:

```bash
# A) does Caddy answer where the containers are pointed?
docker exec nextcloud-caddy sh -c 'netstat -tln | grep LISTEN'
#    need :80, :443, :8444

# B) does the bare WebSocket URL reach signaling, or does Nextcloud answer?
curl -s -H "Host: <NC_DOMAIN>" http://127.0.0.1/standalone-signaling | head -c 40
#    "404 page not found"        -> signaling answered (healthy; no token supplied)
#    "<!DOCTYPE html> ...Nextcloud" -> path matcher bug (F2)
```

| Symptom | Broken path | Go to |
| --- | --- | --- |
| Admin card: **"Error: Cannot connect to server"** | 2 (and usually 3 too) | [F1](#f1-caddy-is-not-listening-on-443) |
| Admin card fine, but the browser's WebSocket never connects; devtools shows a 404 HTML page | 1 | [F2](#f2-path-matcher-misses-the-bare-websocket-url) |
| Calls work, but the signaling log is full of capability errors | 3 | [F6](#f6-signaling-cannot-reach-nextclouds-ocs-api) |
| No such file/console spam about `standalone-signaling`, Talk behaves like internal signaling | registration | [F4](#f4-duplicate-or-missing-registration), [F5](#f5-wrong-domain-or-secret) |
| "Certificate expired" / certificate error in the admin card | registration | [F3](#f3-verify-true-with-a-self-signed-certificate) |

The admin card's wording maps to specific code, which tells you a lot:

| Admin card text | Source | Meaning |
| --- | --- | --- |
| `Error: Cannot connect to server` | `CAN_NOT_CONNECT` in `Signaling\Manager::checkServerCompatibility` | could not open the connection at all |
| `Error: Server did not respond with proper JSON` | `JSON_INVALID` | reached *something*, but it was not the signaling server - almost always [F2](#f2-path-matcher-misses-the-bare-websocket-url) |
| `Error: Certificate expired` | `CERTIFICATE_EXPIRED` | `verify: true` against a self-signed cert - [F3](#f3-verify-true-with-a-self-signed-certificate) |
| `Error: Running version: X; Server needs to be updated` | `UPDATE_REQUIRED` | signaling image too old - bump `strukturag/nextcloud-spreed-signaling` |

Both functions live in `custom_apps/spreed/lib/Signaling/`, and the card is
`custom_apps/spreed/lib/SetupCheck/HighPerformanceBackend.php`. Reading those
files is often faster than guessing.

### 5.2 Failure catalogue

#### F1: Caddy is not listening on 443

**Symptom.** "Error: Cannot connect to server". Signaling log repeats:

```
capabilities.go:386: Could not get capabilities for https://<NC_DOMAIN>/:
  dial tcp 172.18.0.250:443: connect: connection refused
```

**Cause.** `compose.yaml` pins the public domain to `CADDY_INTERNAL_IP` via
`extra_hosts` on the app, cron and signaling containers - but the Caddyfile had
no `:443` listener, so the pin pointed at a dead port. The containers cannot
fall back to the public URL (Funnel does not hairpin), so *both* the app's
back-channel and the signaling server's capability fetches fail.

**Fix.** The Caddyfile needs a container-internal HTTPS site for the public
domain:

```caddyfile
https://{$NC_DOMAIN} {
    tls internal
    handle_path /standalone-signaling* {
        reverse_proxy nextcloud-signaling:8081
    }
    handle {
        reverse_proxy proxy-nginx:80
    }
}
```

Port 443 must stay **unpublished** - only containers need it. Then restart Caddy
([3.3](#33-after-editing-the-caddyfile)) and re-register the HPB without
`--verify` ([F3](#f3-verify-true-with-a-self-signed-certificate)).

#### F2: Path matcher misses the bare WebSocket URL

**Symptom.** Admin card is fine, but the browser's WebSocket never opens.
Devtools shows the upgrade request returning Nextcloud's HTML *Page not found*.

**Cause.** The browser opens the **registered URL verbatim**:
`wss://<NC_DOMAIN>/standalone-signaling` - the bare path, no trailing segment. A
Caddy matcher of `/standalone-signaling/*` matches `/standalone-signaling/` and
anything deeper, but **not** the bare path, so the request fell through to the
`handle` block and Nextcloud answered.

**Fix.** Use `/standalone-signaling*`:

```caddyfile
handle_path /standalone-signaling* {     # NOT  /standalone-signaling/*
    reverse_proxy nextcloud-signaling:8081
}
```

`handle_path` strips the prefix, so `/standalone-signaling` becomes `/` (the
WebSocket endpoint) and `/standalone-signaling/api/v1/...` becomes
`/api/v1/...` (the back-channel API). Apply this on **both** the `:80` and the
`:443` sites.

Confirm with:

```bash
curl -s -H "Host: <NC_DOMAIN>" http://127.0.0.1/standalone-signaling | head -c 40
# want: 404 page not found        (signaling, no token supplied)
# not:  <!DOCTYPE html> ...Nextcloud
```

#### F3: `verify: true` with a self-signed certificate

**Symptom.** "Error: Cannot connect to server" even though Caddy *is*
listening on 443, or a certificate error in the admin card.

**Cause.** The internal listeners use `tls internal`, i.e. a self-signed cert.
spreed only passes `verify => false` to its HTTP client when the stored
signaling entry has `verify: false`. Registered with `--verify`, its cURL calls
fail certificate validation.

**Fix.** Re-register **without** `--verify`. `add` does not overwrite, so
delete first:

```bash
cd /home/mis/docker/nextcloud-stock-customs
docker compose exec -T nextcloud-app php occ talk:signaling:delete \
  "wss://<NC_DOMAIN>/standalone-signaling"
docker compose exec -T nextcloud-app php occ talk:signaling:add \
  "wss://<NC_DOMAIN>/standalone-signaling" <SIGNALING_SECRET>
docker compose exec -T nextcloud-app php occ talk:signaling:list   # expect verify: false
```

`verify: false` costs you only the certificate-expiry warning. It does **not**
weaken anything the browser relies on - browsers still get the real public
certificate from Tailscale Funnel.

#### F4: Duplicate or missing registration

**Symptom.** `talk:signaling:list` shows the same server twice, or zero servers.

**Cause.** `talk:signaling:add` **appends**; it never replaces. Running it twice
(once plain, once with `--verify`) leaves two entries. Talk 24 then warns that
multiple HPBs are deprecated and may pick either one.

**Fix.**

```bash
docker compose exec -T nextcloud-app php occ talk:signaling:list
docker compose exec -T nextcloud-app php occ talk:signaling:delete \
  "wss://<NC_DOMAIN>/standalone-signaling"     # removes ALL entries for that URL
# re-add exactly once - see F3
```

Exactly one entry must remain.

#### F5: Wrong domain or secret

**Symptom.** Registration looks right but nothing connects.

**Cause.** The URL in the registration does not match `NC_DOMAIN`, or has a
trailing slash / scheme / port (`wss://…//standalone-signaling` breaks the
path). Or the secret differs from `SIGNALING_SECRET` in `.env`.

**Fix.** Delete and re-add using values read straight from `.env` - never typed
by hand. The secret is base64 and contains `/`, `+` and `=`, so it must be
quoted:

```bash
cd /home/mis/docker/nextcloud-stock-customs
SECRET=$(grep -E '^SIGNALING_SECRET=' .env | cut -d= -f2-)
DOMAIN=$(grep -E '^NC_DOMAIN=' .env | cut -d= -f2-)
docker compose exec -T nextcloud-app php occ talk:signaling:delete \
  "wss://$DOMAIN/standalone-signaling"
docker compose exec -T nextcloud-app php occ talk:signaling:add \
  "wss://$DOMAIN/standalone-signaling" "$SECRET"
```

`SIGNALING_SECRET` and `INTERNAL_SECRET` must be **equal** - the signaling
container presents `INTERNAL_SECRET` back to Nextcloud, and Nextcloud compares it
against the secret stored by `add`.

#### F6: Signaling cannot reach Nextcloud's OCS API

**Symptom.** Signaling log repeats `Could not get capabilities ... connection
refused` or curl error 60/28, even though the admin card is green.

**Cause.** `SIGNALING_BACKEND_URL` lists URLs the signaling server uses for its
own outgoing calls. It tries them in order and keeps retrying the first one. If
that first URL is unreachable from the container, capabilities never load and
Talk features can be missing.

**Fix.** Check what it is trying and whether that works from inside the
container:

```bash
docker logs --tail 20 nextcloud-signaling 2>&1 | grep -i 'capabilit\|refused'
docker exec nextcloud-signaling env | grep BACKEND_BACKEND1_URLS

# can the signaling container reach its own configured backend?
docker exec nextcloud-cron curl -sSk -m 10 \
  https://<NC_DOMAIN>/ocs/v2.php/cloud/capabilities   # via the :443 pin
docker exec nextcloud-cron curl -sSk -m 10 \
  https://nextcloud-caddy:8444/status.php              # by container name
```

If the first URL in the list is unreachable, reorder `SIGNALING_BACKEND_URL` so
a reachable one comes first, then restart the signaling server. The public URL
in the list is also what spreed uses to match requests, so keep it - just not
necessarily first.

A healthy startup log contains `Received capabilities map[...]` and no
`connection refused`.

#### F7: `CADDY_INTERNAL_IP` drift

**Symptom.** Everything worked, then after a reboot or `docker compose down` +
`up` nothing connects, and `config/talk-hpb-check.sh` fails section 2.

**Cause.** The IP is declared in **two** places that must agree:
`CADDY_INTERNAL_IP` in `.env` (consumed by the `extra_hosts` entries) and
`ipv4_address` under the `caddy` service in `compose.yaml`. If they disagree -
or if the containers were recreated against a stale `.env` - the pin resolves to
an address nothing is listening on.

**Fix.**

```bash
cd /home/mis/docker/nextcloud-stock-customs
grep -E '^CADDY_INTERNAL_IP=' .env
docker network inspect nt_n8n_network \
  -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{println}}{{end}}' | grep caddy
```

Make them equal, then `docker compose up -d` so the containers pick up the new
`extra_hosts`. Recreating `nt_n8n_network` changes the subnet and the static IP
in the same breath, so update both and re-verify with
`config/talk-hpb-check.sh`.

### 5.3 Version-mismatch warning (not a misconfiguration)

```
Server does not support all features of this Talk version, missing features:
changed-users
```

The signaling image is older than the Talk version in Nextcloud. Calls still
work. Bump `strukturag/nextcloud-spreed-signaling` in `compose.yaml` to silence
it.

---

## 6. Changing the domain or the secrets

1. Update `NC_DOMAIN` in `.env`. If the IP changes too, update
   `CADDY_INTERNAL_IP` as well ([F7](#f7-caddy_internal_ip-drift)).
2. If Tailscale is involved, update the Funnel hostname and re-enable Funnel.
3. `docker compose config -q && docker compose up -d`
4. Delete the **old** registration and add the **new** one ([F5](#f5-wrong-domain-or-secret)).
5. Delete and re-add TURN - `talk:turn:delete` removes *all* TURN servers, there
   is no per-server delete, so re-add immediately after:

```bash
docker compose exec -T nextcloud-app php occ talk:turn:delete
docker compose exec -T nextcloud-app php occ talk:turn:add \
  turn <NC_DOMAIN> udp,tcp --secret=<TURN_SECRET>
```

6. `bash config/talk-hpb-check.sh`

For a **secret** change alone, only step 4 applies - plus remember
`SIGNALING_SECRET`, `INTERNAL_SECRET` and `TURN_SECRET` all move together, and
the signaling container must be restarted to reload them.

---

## 7. Verifying a fix

```bash
cd /home/mis/docker/nextcloud-stock-customs
bash config/talk-hpb-check.sh        # everything green, exit 0
```

Then in a browser: **Administration settings → Talk**. The High-performance
backend card must show **connected** with a feature list, not an error. Then
actually start a call - the setup check can pass while media is still broken if
TURN is not reachable.

A 404 from `https://<NC_DOMAIN>/standalone-signaling/` is **normal** - that
endpoint only answers a WebSocket upgrade, not a plain GET. Do not chase it.

To watch a call work end to end:

```bash
docker logs -f nextcloud-signaling
#    clients connecting, and no 'connection refused' or capability errors
```
