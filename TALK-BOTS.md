<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Talk bots and webhooks - installation and operations runbook

How to install a **Nextcloud Talk bot** (a webhook receiver) on this stack, how to
wire it to a container that lives on the same Docker network, and how to tell
whether it is actually working.

This is the procedure used to install **Ami**, the help-desk bot that lives in
`/home/mis/docker/ami-nextcloud-talk` on the same host as this stack.

Companion documents: [TALK-HPB.md](TALK-HPB.md), [TALK-HPB-RUNBOOK.md](TALK-HPB-RUNBOOK.md),
[NETWORKING.md](NETWORKING.md).

---

## TL;DR quick card

```bash
cd /home/mis/docker/nextcloud-stock-customs

# 1. Is the bot registered on the server?
docker compose exec -T nextcloud-app php occ talk:bot:list

# 2. Which conversations is it enabled in?
docker compose exec -T nextcloud-app php occ talk:bot:list <room-token>

# 3. Can a container on the docker network reach Nextcloud?
docker exec <bot-container> node -e 'require("http").get(
  {host:"nextcloud-caddy",port:80,path:"/status.php"},r=>console.log(r.statusCode))'

# 4. Register a new bot (idempotency: install does NOT overwrite, remove first)
docker compose exec -T nextcloud-app php occ talk:bot:remove <bot-id>
docker compose exec -T nextcloud-app php occ talk:bot:install \
  "<name>" "<secret-40-to-128-chars>" "http://<bot-container>:<port>/<webhook-path>" \
  -f webhook -f response

# 5. Enable the bot in the conversations it should answer in
docker compose exec -T nextcloud-app php occ talk:bot:setup <bot-id> <room-token> [<room-token>...]
```

**One-line decision rule:** a Talk bot is working when **all four** of these are
true: the bot is in `oc_talk_bots_server`, it is in `oc_talk_bots_conversation` for
the room, the bot container can reach `nextcloud-caddy:80` from inside the network,
and a message posted in that room reaches the bot's log. Anything else is one of
the failures in [section 6](#6-troubleshooting).

---

## 1. The three request paths

A Talk bot is **webhook-based**. It never polls. There are three independent
request paths, and a bot that "does not answer" is almost always broken on one of
them. Identifying which one is 90% of the debugging.

```
 (A) INBOUND   user posts in a Talk room
                        |
                        v
              Nextcloud Talk (inside nextcloud-app)
                        |  HTTP POST <bot-url>            <- path (A)
                        |  + HMAC signature headers
                        v
              <bot-container>:<port>/<webhook-path>
              e.g. ami-talk-bot:3979/api/talk/webhook

 (B) OUTBOUND  bot posts its reply back into the room
                        |
                        v
              bot container --> Caddy :80                <- path (B)
                                (Host: nextcloud-caddy)
                                    |
                                    v
                              proxy-nginx --> nextcloud-app --> Talk

 (C) CONTROL   bot asks "am I admin?" / "am I owner?" / "enable me here"
                        |
                        v
              bot container --> Caddy :80                <- path (C)
                                + HTTP Basic auth (admin account)
                                    |
                                    v
                              Nextcloud OCS API
```

Path (A) is what makes the bot appear in the UI and receive messages. Path (B) is
what makes it reply. Path (C) is what gates its admin commands. **A bot can have
(A) working and (B) broken**, which looks like "it sees messages but never
answers" - and is the most common partial failure.

---

## 2. Choosing the webhook URL: use the container name

The webhook URL stored in `oc_talk_bots_server.url` is called by Nextcloud, and
Nextcloud runs on the same Docker network as the bot. **Do not publish a host
port and do not use the public hostname.** Register the container name:

```
http://<compose-service-name>:<port><webhook-path>
```

For Ami that is `http://ami-talk-bot:3979/api/talk/webhook`.

Why not the public URL:

- The public endpoint is Tailscale Funnel on `100.x.64.x.25:443`. It does **not
  hairpin** back into a container on the same host, so if you register
  `https://<NC_DOMAIN>/...` Nextcloud will hang until the request times out. See
  [TALK-HPB-RUNBOOK.md](TALK-HPB-RUNBOOK.md) for the same failure in the HPB.
- Publishing a port would expose the webhook to anything that can reach the host,
  for no benefit. The webhook is authenticated by HMAC, but there is no reason to
  widen the attack surface.

Consequences to plan for:

- The bot must be on the **same Docker network** as the Nextcloud stack. Confirm
  with `docker inspect <bot-container> --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'`.
- The webhook port must **not** be bound to a specific host interface in a way
  that makes it container-unreachable. A plain `ports: - "3979"` publish is
  unnecessary.
- The bot should **not** verify TLS. Plain HTTP is correct here because every
  request carries an HMAC signature over its own body (see section 4).

---

## 3. Registering the bot

```bash
cd /home/mis/docker/nextcloud-stock-customs
SECRET=$(openssl rand -hex 24)     # 48 hex chars, comfortably in the 40..128 range
echo "$SECRET"                     # store this in the bot's env file

docker compose exec -T nextcloud-app php occ talk:bot:install \
  "Ami" \
  "$SECRET" \
  "http://ami-talk-bot:3979/api/talk/webhook" \
  "Ami help desk assistant" \
  -f webhook -f response
```

Prints `Bot installed` and an `ID:`. Record it - `talk:bot:setup` needs it, and
most bots also want it in their own config as `TALK_BOT_ID`.

### Feature flags

`-f` is `--feature` (singular, repeatable). Choose only what the bot implements:

| Feature    | Grants                                                  | Ami |
|------------|---------------------------------------------------------|-----|
| `webhook`  | receives posted chat messages as webhooks              | yes |
| `response` | posts messages and reactions back into the room        | yes |
| `event`    | reads the local event stream (`/bot/events`)            | no  |
| `reaction` | notified when reactions are added or removed           | no  |
| `none`     | disables all features - useful for a dry run           | no  |

Granting a feature the bot never calls produces silent no-ops, so do not add them
speculatively.

### Re-installing does not overwrite

`talk:bot:install` creates a *new* server-wide bot. To change the URL or secret
of an existing bot you must remove it first, otherwise you accumulate duplicates
and messages fan out to all of them:

```bash
docker compose exec -T nextcloud-app php occ talk:bot:remove <bot-id>
```

### Enable it per conversation

Installing registers the bot server-wide; it is still silent until it is enabled in
a conversation.

```bash
docker compose exec -T nextcloud-app php occ talk:bot:setup 1 7mhyekm4 3mvk82zz
```

Or, without `occ`, from the Talk UI: open the conversation, then
**Add participant -> Bots -> Ami**. This fires the `Join` webhook that Ami uses to
auto-approve the room.

To change features or state later:

```bash
docker compose exec -T nextcloud-app php occ talk:bot:state <bot-id> -f webhook
```

---

## 4. Signature scheme

Both directions are authenticated with HMAC-SHA256 keyed on the shared secret.
There is no bearer token and no session cookie.

**Talk -> bot** (inbound). Talk sends the raw JSON body plus two headers, and the
bot must verify against the **raw bytes** - re-serializing the parsed JSON breaks
the hash:

```
X-Nextcloud-Talk-Random:    <64 random chars>
X-Nextcloud-Talk-Signature: hex(hmac_sha256(secret, random + raw_body))
```

**Bot -> Talk** (outbound reply). The bot signs the **message text**, not the
JSON envelope, because Talk looks the room up from the URL path and matches the
secret against every bot enabled in that room:

```
POST <server>/ocs/v2.php/apps/spreed/api/v1/bot/<roomToken>/message

X-Nextcloud-Talk-Bot-Random:    <64 random hex chars>
X-Nextcloud-Talk-Bot-Signature: hex(hmac_sha256(secret, random + message_text))
OCS-APIRequest:                 true
```

Signing the JSON body instead of the message text is the single most common cause
of an `HTTP 400` from a reply that "looks" correctly authenticated.

The bot's own control calls - "is this user an admin", "is the admin an owner of
this room", "enable the bot in this room" - are **not** signed. They use HTTP
Basic auth with a Nextcloud account:

```
GET  <server>/ocs/v2.php/cloud/users/<uid>          -> is the user in the admin group
GET  <server>/ocs/v2.php/apps/spreed/api/v4/room/<token>/participants
POST <server>/ocs/v2.php/apps/spreed/api/v1/bot/<roomToken>/<botId>
```

So a bot with an **empty** `TALK_ADMIN_USER` still receives messages and still
replies, but every admin command is refused and no room ever auto-approves. That
failure is easy to misread as "the bot is broken".

---

## 5. The reverse direction: making the bot reach Nextcloud

A bot that can receive webhooks still has to reach Nextcloud to post its replies.
`TALK_SERVER_URL` must be an **internal** URL, for the same no-hairpin reason as
section 2:

```
TALK_SERVER_URL=http://nextcloud-caddy
```

The Caddyfile provides a container-internal plain-HTTP site that matches only the
literal `Host: nextcloud-caddy` and rewrites it to the public trusted domain so
Nextcloud's `trusted_domains` check passes. Plain HTTP is appropriate because the
requests are HMAC-signed. The block is documented inline in the Caddyfile; see the
`http://nextcloud-caddy` site.

Verify from inside the bot container:

```bash
docker exec ami-talk-bot node -e 'require("http").get(
  {host:"nextcloud-caddy",port:80,path:"/status.php"},
  r=>console.log("status",r.statusCode))'
# expect: status 200
```

Then recreate the bot so it picks up the new value. A changed `env_file` does
**not** take effect on `docker compose restart` - the values are baked into the
container at create time:

```bash
cd /home/mis/docker/ami-nextcloud-talk
docker compose up -d --force-recreate
```

---

## 6. Troubleshooting

Work top to bottom; each step isolates one of the three paths from section 1.

### Symptom: the bot never appears in a conversation, or messages get no reply

| Check | Command | Expect |
|-------|---------|--------|
| Registered? | `occ talk:bot:list` | one row with your `url` |
| Enabled in room? | `occ talk:bot:list <token>` | the bot is listed |
| DB truth | `select id,name,url,features from oc_talk_bots_server;` | one row |
| Path A alive? | `docker logs --tail 50 <bot> \| grep 'POST /api/talk/webhook'` | one line per message |
| Path B alive? | signed POST test, see below | `HTTP 200` |

`POST <bot-url>` returning **404** is healthy: it means Nextcloud reached the bot
and express routed the path, but the route is `POST`-only. A connection error or a
timeout instead means path A is broken.

### Symptom: `HTTP 400` on a reply

Almost always the outbound signature. Confirm the bot signs `random + message_text`
rather than `random + json_body` (section 4). Check the bot log for
`Failed to post reply to room` with the status.

### Symptom: `⛔ Only the Nextcloud admin can manage Ami` / rooms never auto-approve

`TALK_ADMIN_USER` or `SECRET_TALK_ADMIN_PASSWORD` is empty, so every
`isUserAdmin` / `isAdminModeratorInRoom` call short-circuits to `false` without
ever reaching the network. There is nothing in the log to show this - it fails
silently, which is why it looks like a broken bot.

```bash
grep -E '^TALK_ADMIN_USER=|^SECRET_TALK_ADMIN_PASSWORD=' \
  /home/mis/docker/ami-nextcloud-talk/env/.env.dev.user
# both must be non-empty
```

An app password is preferable to the real account password because it is scoped
and revocable:

```bash
docker compose exec -T nextcloud-app php occ user:auth-tokens:add admin ami-talk
```

### Symptom: bot receives the message but never replies

Path A works and path B is broken. Walk section 5, then re-run the signed POST
test:

```bash
docker exec ami-talk-bot node -e '
const crypto=require("crypto"),http=require("http");
const text="connectivity test", room="<roomToken>";
const r=crypto.randomBytes(32).toString("hex");
const s=crypto.createHmac("sha256",process.env.SECRET_TALK_SECRET).update(r+text).digest("hex");
const body=JSON.stringify({message:text});
const q=http.request({host:"nextcloud-caddy",port:80,method:"POST",
  path:"/ocs/v2.php/apps/spreed/api/v1/bot/"+room+"/message",
  headers:{"Content-Type":"application/json","OCS-APIRequest":"true","Accept":"application/json",
    "X-Nextcloud-Talk-Bot-Random":r,"X-Nextcloud-Talk-Bot-Signature":s,
    "Content-Length":Buffer.byteLength(body)}},
  res=>{let b="";res.on("data",d=>b+=d);res.on("end",()=>console.log(res.statusCode,b))});
q.end(body);'
```

### Symptom: it worked, then a restart broke it

Two things do not survive a naive restart:

1. A changed `env_file` is ignored by `docker compose restart`. Use
   `docker compose up -d --force-recreate`.
2. The bot's own state lives in a **volume** (`/app/data` for Ami) holding
   `approved-rooms.json` and `notify-rooms.json`. If the volume was recreated the
   bot starts with zero approved rooms and silently ignores every message. Check
   the startup log for `Loaded 0 approved room(s)`.

### Symptom: duplicate replies

More than one row in `oc_talk_bots_server` - usually a re-install that was never
cleaned up. Remove the stale id with `talk:bot:remove`.

---

## 7. Reference

### `occ talk:bot:*` commands

| Command | Purpose |
|---------|---------|
| `talk:bot:list [<token>]` | list server-wide bots, or bots in one conversation |
| `talk:bot:install <name> <secret> <url> [description]` | register a bot (adds, never updates) |
| `talk:bot:uninstall <id>` | remove a bot from the server |
| `talk:bot:setup <bot-id> [<token>...]` | enable the bot in conversations |
| `talk:bot:remove <id> [<token>]` | disable the bot in a conversation |
| `talk:bot:state <bot-id>` | change features or state |
| `talk:bot:create <name> <secret> <url>` | shorthand for a `response`-only bot |

Constraints enforced by `talk:bot:install`: name 1-64 chars, secret **40-128
chars**, url up to 4000 chars.

### Relevant tables

| Table | Contents |
|-------|----------|
| `oc_talk_bots_server` | server-wide registration: `id`, `name`, `url`, `secret`, `features` |
| `oc_talk_bots_conversation` | per-conversation enablement and state |

### Useful bot environment variables (Ami)

| Variable | Purpose |
|----------|---------|
| `TALK_SERVER_URL` | internal base URL, `http://nextcloud-caddy` |
| `SECRET_TALK_SECRET` | shared secret, must match `talk:bot:install` |
| `TALK_BOT_ID` | numeric id from `talk:bot:install`, default `1` |
| `TALK_WEBHOOK_PATH` | default `/api/talk/webhook` |
| `TALK_ADMIN_USER` | Nextcloud account used for control calls and the static admin list |
| `SECRET_TALK_ADMIN_PASSWORD` | password or app password for that account |
| `PORT` | default `3979` |

### Health endpoint

Bots built on Ami's layout expose `GET /api/health`:

```json
{"status":"healthy","company":"...","channel":"nextcloud-talk",
 "talkConfigured":true,"activeConversations":0,"timestamp":"..."}
```

`talkConfigured: false` means `TALK_SERVER_URL` or the secret is missing, so the
process is up but cannot sign replies.
