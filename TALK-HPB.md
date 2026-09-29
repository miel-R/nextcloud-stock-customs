<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Talk High-performance backend (HPB) - install & register

How to enable **Nextcloud Talk**'s High-performance backend on this stack and
register the built-in `signaling` (HPB) + `turn` (STUN/TURN) containers in
Nextcloud. This is the condensed, copy-paste guide for registering the servers
that ship with `compose.yaml` - no extra installs, no `npm`, no systemd unit,
nothing outside this repo's containers.

> **Operating it?** This document covers install and registration. For
> restarting, health checks and troubleshooting a broken HPB, see
> **[TALK-HPB-RUNBOOK.md](TALK-HPB-RUNBOOK.md)** and run
> `bash config/talk-hpb-check.sh`.

> This is the **standalone HPB** pattern (one signaling container per Nextcloud
> instance, `strukturag/nextcloud-spreed-signaling`). It is *not* "shared HPB".
> For many instances behind one signaling server, see the upstream
> [nextcloud-spreed-signaling](https://github.com/strukturag/nextcloud-spreed-signaling)
> docs.
>
> King rule: **`occ` talks to Nextcloud through the app service, never by
> container name.** See ["the #1 way this fails"](#the-1-way-this-fails).

---

## TL;DR - copy-paste that works

Run on the host, **in the repo directory**, after the stack is up and the
Nextcloud web installer has completed (`occ status` prints `installed: true`).

```bash
cd /path/to/nextcloud-stock-customs    # where compose.yaml is

# 1) make sure the Talk app is on (idempotent - safe to re-run)
docker compose exec -T nextcloud-app php occ app:enable spreed

# 2) register the HPB signaling server (see step 2.2 below for the real values)
#    NO --verify on this topology: Caddy serves the containers a self-signed
#    `tls internal` cert, so Nextcloud must skip verification. See section 8.
docker compose exec -T nextcloud-app php occ talk:signaling:add \
  "wss://<NC_DOMAIN>/standalone-signaling" <SIGNALING_SECRET>

# 3) register TURN
docker compose exec -T nextcloud-app php occ talk:turn:add \
  turn <NC_DOMAIN> udp,tcp --secret=<TURN_SECRET>

# 4) confirm
docker compose exec -T nextcloud-app php occ talk:signaling:list
docker compose exec -T nextcloud-app php occ talk:turn:list
```

> `-T` disables pseudo-TTY allocation. Keep it when running over SSH / scripts /
> agents (a plain non-tty shell without `-T` can fail with *"the input device is
> not a TTY"*). In an interactive terminal `-T` still works fine - use it always.

**Worked example (state verified on the mis server, Sep 2026):**

```bash
cd /home/mis/docker/nextcloud-stock-customs

docker compose exec -T nextcloud-app php occ app:enable spreed

docker compose exec -T nextcloud-app php occ talk:signaling:add \
  "wss://mis-server.tail204a2d.ts.net/standalone-signaling" \
  "j2TCikAsvL4dOq+x6AUN1RI+I0hbybgZPG5xUjjz5Uc="

docker compose exec -T nextcloud-app php occ talk:turn:add \
  turn mis-server.tail204a2d.ts.net udp,tcp \
  --secret=j2TCikAsvL4dOq+x6AUN1RI+I0hbybgZPG5xUjjz5Uc=
```

> Replace the **domain** and **secret** with your own - see
> [step 2](#2-prepare-the-real-values). The secret shown is the repo's demo
> value, it must match your `SIGNALING_SECRET=` / `TURN_SECRET=` in `.env`
> exactly.

---

## Why it is not "automatic" (and this is by design)

The two containers **start automatically** with the stack (`docker compose ps`
shows `nextcloud-signaling` / `nextcloud-turn` up). What Nextcloud still does
**not** know is *which* signaling server to talk to - that is stored in its own
database by the `talk:` occ commands, because those commands:

- need the app to be **installed** first (`talk:` commands literally do not exist
  until `occ status` → `installed: true`),
- need the **public URL** the signaling server is reachable over (only known
  after step 1's Tailscale/DNS choice),
- verify the shared **secret** against a running container.

So there is no "flip a switch" install: the three `interactive-looking` occ
commands above are the whole registration. The rest of this doc is exactly what
those commands need and how to fix them when they error.

---

## The #1 way this fails

Bad: `docker exec nextcloud-app php occ …`

```
Error response from daemon: No such container: nextcloud-app
```

Good: `docker compose exec -T nextcloud-app php occ …`

The real container is `nextcloud-stack-nextcloud-app-1` (project name + service
name + suffix), and the prefix changes if you rename the folder. `docker compose
exec` resolves it for you. See [INSTALL.md](INSTALL.md) step 11.

The second most common failure: `occ talk:signaling:remove` →

```
Command "talk:signaling:remove" is not defined.
Did you mean one of these? ... talk:signaling:delete ...
```

The verb is **`delete`** (`talk:signaling:delete`), not `remove`.

---

## 1. Prerequisites - the 4 checks

```bash
cd /path/to/nextcloud-stock-customs

# 1. the signaling + turn containers are actually up
docker compose ps | grep -E 'signaling|turn'
#    nextcloud-signaling ... Up
#    nextcloud-turn      ... Up (healthy)

# 2. Nextcloud itself is installed (talk: commands exist only then)
docker compose exec -T nextcloud-app php occ status
#    - installed: true   <-- required

# 3. the Talk app (spreed) is enabled (idempotent)
docker compose exec -T nextcloud-app php occ app:enable spreed

# 4. the >= 3 Talk secrets are the real values in .env (not CHANGE_ME_*)
grep -E '^(SIGNALING_SECRET|INTERNAL_SECRET|TURN_SECRET)=' .env
```

If `installed: false`, finish the Nextcloud web installer first (INSTALL.md
step 8) - `talk:signaling:add` will say **"no commands defined in the
talk namespace"** until then.

> **`SIGNALING_SECRET` and `INTERNAL_SECRET` must be equal.** The signaling
> container uses `SIGNALING_SECRET` for its backend, `INTERNAL_SECRET` as the
> token it presents back to Nextcloud; Nextcloud compares the token it stored
> (`talk:signaling:add`) against `INTERNAL_SECRET`. If they differ, verification
> fails. Default `.env.example` sets all three to separate values - set them
> equal or register with `INTERNAL_SECRET`'s value.

---

## 2. Prepare the real values (domain + secrets)

Read the actual values **from `.env`** - never type placeholders, never guess:

```bash
cd /path/to/nextcloud-stock-customs
grep -E '^(NC_DOMAIN|SIGNALING_SECRET|TURN_SECRET)=' .env
```

| Variable | You will use it as | Cannot be |
| --- | --- | --- |
| `NC_DOMAIN` | `wss://<NC_DOMAIN>/standalone-signaling` and TURN server name | with a trailing `/`, a scheme, or a port |
| `SIGNALING_SECRET` | the secret passed to `talk:signaling:add` | stale / truncated / `CHANGE_ME_*` |
| `TURN_SECRET` | `--secret=` of `talk:turn:add` | different from the signaling secret |

> **On a fresh deploy, forget the old server's secrets.** If this Nextcloud was
> previously registered against a signaling container that used *other* secrets
> (e.g. an earlier install), delete the old entry first - see
> [step 4](#4-cleanup-duplicates-stale-entries).

---

## 3. Register (the commands)

### 3.1 Signaling (HPB)

```bash
docker compose exec -T nextcloud-app php occ talk:signaling:add \
  "wss://<NC_DOMAIN>/standalone-signaling" <SIGNALING_SECRET>
```

- `<server>` is the **WebSocket** URL the *browser* connects to. With TLS
  terminated at the edge (Tailscale Funnel / Let's Encrypt) this is
  `wss://<NC_DOMAIN>/standalone-signaling`. The `Caddyfile` already proxies
  `/standalone-signaling` → `signaling:8081` (on both the public `:80` site and
  the internal `:443` site), and the signaling container's own backend uses
  `https://<NC_DOMAIN>` (`BACKEND_BACKEND1_URLS`), so no other route is needed.
- `<SIGNALING_SECRET>` is the raw base64 from `.env` - paste the value in quotes:
  it contains `/`, `+`, `=` which the shell would otherwise eat:
  `"j2TCikAsvL4dOq+x6AUN1RI+I0hbybgZPG5xUjjz5Uc="`.
- **Do not pass `--verify` on this topology.** Caddy hands the containers a
  self-signed `tls internal` certificate, so Nextcloud must skip verification.
  Without `--verify` the entry is stored with `verify: false`, and spreed then
  passes `verify => false` to its HTTP client both in the admin setup check
  (`Signaling\Manager::checkServerCompatibility`) and in the back-channel
  notifications (`Signaling\BackendNotifier::backendRequest`). With `--verify`
  those cURL calls fail on the self-signed cert and the admin card reports
  *"Error: Cannot connect to server"*.
  `verify: false` costs you the certificate-expiry warning only.
- Run the add **once**. It does *not* overwrite an existing entry - running `add`
  twice creates two entries (see [step 4](#4-cleanup-duplicates-stale-entries)).

### 3.2 TURN

```bash
docker compose exec -T nextcloud-app php occ talk:turn:add \
  turn <NC_DOMAIN> udp,tcp --secret=<TURN_SECRET>
```

- argument order: **schemes** (`turn` / `turn,turns`), **server** (plain domain,
  no scheme, no port), **protocols** (`udp,tcp`), then `--secret=` with the value
  glued right after the `=` (no space, no quotes, no angle brackets).
- `--secret=` value = your `TURN_SECRET`.

---

## 4. Cleanup - duplicates / stale entries

### 4.1 Remove duplicates (you ran add twice)

```bash
# list - duplicates show as the same server in multiple entries:
docker compose exec -T nextcloud-app php occ talk:signaling:list

# delete ALL entries for that URL (including duplicates), then add exactly once:
docker compose exec -T nextcloud-app php occ talk:signaling:delete \
  "wss://<NC_DOMAIN>/standalone-signaling"
docker compose exec -T nextcloud-app php occ talk:signaling:add \
  "wss://<NC_DOMAIN>/standalone-signaling" <SIGNALING_SECRET>
docker compose exec -T nextcloud-app php occ talk:signaling:list
# expect exactly ONE entry with verify: false
```

### 4.2 Changed the domain or secret?

Same delete-then-add, with the **old** values in `delete` and the **new** ones
in `add`. For TURN, `talk:turn:delete` removes **all** TURN servers (there is no
per-server delete), so re-run `talk:turn:add` right after:

```bash
docker compose exec -T nextcloud-app php occ talk:turn:delete
docker compose exec -T nextcloud-app php occ talk:turn:add \
  turn <NC_DOMAIN> udp,tcp --secret=<TURN_SECRET>
```

---

## 5. Verify it is actually working

```bash
docker compose exec -T nextcloud-app php occ talk:signaling:list
#  servers:
#    0:
#      server: wss://mis-server.tail204a2d.ts.net/standalone-signaling
#      verify: false          <-- expected on this topology (see section 8)
#  secret: j2TCik...=        <-- matches your SIGNALING_SECRET

docker compose exec -T nextcloud-app php occ talk:turn:list
#  0:
#    schemes: turn
#    server: mis-server.tail204a2d.ts.net
#    secret: j2TCik...=
#    protocols: udp,tcp
```

Also confirm Caddy is actually answering on the port the containers are pinned to
(`CADDY_INTERNAL_IP`, port 443) - see
["section 8"](#8-ubuntu--plain-linux--tailscale-funnel-internal-routing-fix):

```bash
docker exec nextcloud-cron curl -sSk -m 10 \
  https://<NC_DOMAIN>/standalone-signaling/api/v1/welcome
# {"nextcloud-spreed-signaling":"Welcome","version":"2.1.1~docker"}
```

And that the signaling server can reach Nextcloud's OCS API (no
`connection refused` in its log):

```bash
docker logs --tail 20 nextcloud-signaling 2>&1 | grep -i 'capabilit\|refused'
#    Received capabilities map[...] from https://<NC_DOMAIN>/ocs/v2.php/cloud/capabilities
```

In the browser: **Administration settings → Talk** (or `/index.php/settings/
admin/talk`). The High-performance backend card should show **connected** with a
feature list (audio-video-permissions, chat-relay, federation, hello-v2,
join-features, switchto, virtual-sessions, ...). That clears the
*"Error: Cannot connect to server"* warning and lifts the ~2-3 callers cap.

> `curl https://<NC_DOMAIN>/standalone-signaling/` returning **404 is normal** -
> that endpoint only answers the WebSocket upgrade handshake, not a plain GET.

---

## 8. Ubuntu / plain Linux + Tailscale Funnel: internal routing fix

**On Docker Desktop (Windows/Mac)** the public `https://<NC_DOMAIN>` hairpins
back into containers, so the Talk app's back-channel POSTs to
`https://<NC_DOMAIN>/standalone-signaling/api/v1/room/...` work out of the box.

**On a plain Linux host** where Tailscale Funnel binds only to the Tailscale IP
(`100.119.x.x:443`) and **does not hairpin**, the app's container cannot reach
the public URL — it times out (cURL error 28) or fails cert validation (cURL
error 60) on the self-signed internal cert.

This stack includes the fix in `compose.yaml` + `Caddyfile`:

1. **`extra_hosts` on `nextcloud-app` and `nextcloud-cron`**  
   Pins `<NC_DOMAIN>` to Caddy's static internal IP (`CADDY_INTERNAL_IP`,
   default `172.18.0.250`). The app's HTTPS request lands on Caddy inside the
   bridge network, not the public Funnel.

2. **Internal Caddy HTTPS listener on `:443`** (`tls internal`)  
   The pin in (1) is only half the fix - something has to ANSWER on 443. The
   container-internal listener does, and it is the one the back-channel
   actually hits, because spreed derives that URL from the registered server
   URL and hardcodes `https://` on the default port
   (`Signaling\BackendNotifier::backendRequest` and
   `Signaling\Manager::checkServerCompatibility` both do
   `$url = 'https://' . substr($url, 6);`):
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
   The app POSTs to `https://<NC_DOMAIN>/standalone-signaling/...` → Caddy
   `:443` → signaling:8081. Port 443 is intentionally **not** published to the
   host - only the containers need it.

   > **The matcher must be `/standalone-signaling*`, not
   > `/standalone-signaling/*`.** The browser opens its WebSocket against the
   > registered URL verbatim, i.e. the BARE path `/standalone-signaling`. A
   > `/*` matcher does not match that (it only matches `/standalone-signaling/`
   > and deeper), so the upgrade request fell through to the `handle` block and
   > Nextcloud answered with its "Page not found" HTML page.

3. **Register signaling with `verify:false` (omit `--verify`)**  
   The internal cert is self-signed (`tls internal`). Nextcloud's cURL calls to
   the signaling server must skip cert validation, which spreed only does when
   the stored entry has `verify: false`:
   ```bash
   docker compose exec -T nextcloud-app php occ talk:signaling:delete \
     "wss://<NC_DOMAIN>/standalone-signaling"
   docker compose exec -T nextcloud-app php occ talk:signaling:add \
     "wss://<NC_DOMAIN>/standalone-signaling" <SIGNALING_SECRET>
   # NOTE: NO --verify  ->  verify: false
   ```
   `add` does not overwrite, hence the `delete` first.

4. **Signaling container: `SKIP_VERIFY=true`**  
   The signaling server reaches Nextcloud's OCS backend at
   `https://nextcloud-caddy:8444` (internal Caddy listener, also `tls internal`).
   It must skip cert validation:
   ```yaml
   # in compose.yaml signaling.environment
   SKIP_VERIFY: true
   ```

5. **Add `nextcloud-caddy` to `NEXTCLOUD_TRUSTED_DOMAINS`**  
   The 8444 listener rewrites `Host` to `<NC_DOMAIN>`, but as a belt-and-suspenders
   fix, add the container name to trusted domains so Nextcloud never 400s:
   ```bash
   # in .env or via occ
   NEXTCLOUD_TRUSTED_DOMAINS=... nextcloud-caddy
   ```

Items 1, 4 and 5 are wired in `compose.yaml`. Item 2 (the `:443` listener) and
item 3 (`verify: false`) are **runtime choices you must make yourself** - they
cannot live in `compose.yaml`, so a fresh install that skips them comes up with
a silently broken HPB.

Just set in your `.env` (see `.env.example`):
```
CADDY_INTERNAL_IP=172.18.0.250
SIGNALING_BACKEND_URL=https://nextcloud-caddy:8444
SIGNALING_BACKEND_PORT=8444
SKIP_VERIFY=true
```

### 8.1 Diagnosing a dead HPB

Two independent failures both look like "the HPB is broken". Tell them apart:

```bash
# Q: is anything listening on the pinned IP, port 443?
docker exec nextcloud-caddy sh -c 'netstat -tln | grep LISTEN'
#    need :::443  ->  otherwise the extra_hosts pin points at a dead port

# Q: does the bare WebSocket path reach signaling, or does Nextcloud answer?
curl -s -H "Host: <NC_DOMAIN>" http://127.0.0.1/standalone-signaling | head -c 40
#    "404 page not found"        -> signaling (good, no token was supplied)
#    "<!DOCTYPE html> ...Nextcloud" -> matcher bug, the /* pattern did not match
```

The admin card's *"Error: Cannot connect to server"* is emitted by
`spreed/lib/SetupCheck/HighPerformanceBackend.php` when
`Signaling\Manager::checkServerCompatibility()` cannot reach
`https://<NC_DOMAIN>/standalone-signaling/api/v1/welcome`. That is a
**server-side** call from the app container, so it is the `:443`-listener
problem, not a browser/WebSocket problem.

---

## 9. Symptom → fix

| Symptom | Cause / fix |
| --- | --- |
| `No such container: nextcloud-app` | You used `docker exec`. Use `docker compose exec -T nextcloud-app …` (the container is `nextcloud-stack-nextcloud-app-1`) |
| `the input device is not a TTY` | Running without a terminal (SSH/script). Add `-T`: `docker compose exec -T nextcloud-app …` |
| `Command "talk:signaling:remove" is not defined` / "no commands defined in the talk:signaling namespace" | Wrong verb - use `talk:signaling:delete`. And the `talk:` commands only exist after `occ status` → `installed: true` (finish the web installer first) |
| `talk:signaling:list` shows the server with `verify: false` | **Expected on this topology** - Caddy serves the containers a self-signed `tls internal` cert. See [section 8](#8-ubuntu--plain-linux--tailscale-funnel-internal-routing-fix) |
| `talk:signaling:list` shows the server with `verify: true` but the card errors | Re-register without `--verify` (section 8, step 3) |
| `talk:signaling:list` shows the same server twice | You ran `add` twice (`add` does not replace). Clean up with step 4.1 |
| "Error: Cannot connect to server" in the HPB card | Caddy is not listening on `:443` at `CADDY_INTERNAL_IP`, so the app container's `https://<NC_DOMAIN>/standalone-signaling/api/v1/welcome` is refused. Add the `https://{$NC_DOMAIN}` `tls internal` listener ([section 8](#8-ubuntu--plain-linux--tailscale-funnel-internal-routing-fix) step 2) and register without `--verify`. Diagnose with [8.1](#81-diagnosing-a-dead-hpb) |
| Browser WebSocket never connects, but the admin card is OK | Path-matcher bug: `handle_path /standalone-signaling/*` does not match the bare `/standalone-signaling` the browser opens. Use `/standalone-signaling*` |
| Talk shows an HTML "Page not found" where the signaling server should be | Same path-matcher bug - Nextcloud's `handle` fallback answered instead of signaling |
| "Server does not support all features of this Talk version, missing features: changed-users" | Version gap between `strukturag/nextcloud-spreed-signaling:2.1.1` and Talk. Not a misconfiguration - calls work; bumping the image silences it |
| Old domain registered, calls go nowhere | `NC_DOMAIN` changed. Delete + re-add with the new value (step 4.2) |
| TURN not reachable | `talk:turn:add` used a scheme (`https://…`) or a port (not plain `turn <NC_DOMAIN>`), or port **3478 TCP+UDP** is closed. The stack publishes `3478/udp` + `3478/tcp` by default |

---

## 7. Related

- **[TALK-HPB-RUNBOOK.md](TALK-HPB-RUNBOOK.md)** - operations: restarting the
  stack, `bash config/talk-hpb-check.sh`, and the full failure catalogue.
- `INSTALL.md` step 11 - same commands in the full install runbook.
- `readme.md` → Talk - the container wiring (`BACKEND_BACKEND1_URLS`,
  `SKIP_VERIFY`, `ETURNAL_RELAY_IPV4_ADDR`) behind the scenes.
- Upstream: [nextcloud-spreed-signaling](https://github.com/strukturag/nextcloud-spreed-signaling),
  [eturnal](https://github.com/processone/eturnal).