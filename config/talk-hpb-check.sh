#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# talk-hpb-check.sh - Talk High-performance backend health check
#
# Run it on the host, from the repo directory (where compose.yaml and .env are):
#
#     bash config/talk-hpb-check.sh
#
# It is read-only: it never restarts, recreates or writes anything. Every check
# prints PASS / FAIL / WARN with the reason, so a red run tells you which of the
# three HPB request paths is broken. Exit code is 0 when nothing FAILed, 1
# otherwise, so it can be used from a health monitor.
#
# The three request paths this verifies (see TALK-HPB-RUNBOOK.md):
#   1. browser  --wss-->  Caddy :80   --> signaling:8081
#   2. app      --POST-> Caddy :443  --> signaling:8081   (extra_hosts pin)
#   3. signaling --> Nextcloud OCS API (via Caddy :443 or :8444)
# ---------------------------------------------------------------------------
set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENVFILE="${ENVFILE:-$REPO/.env}"
cd "$REPO" || exit 1

FAIL=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }
head1() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---- read the values that must agree with each other -----------------------
getenv_() { grep -E "^$1=" "$ENVFILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//'; }
NC_DOMAIN="$(getenv_ NC_DOMAIN)"
CADDY_IP="$(getenv_ CADDY_INTERNAL_IP)"
: "${CADDY_IP:=172.18.0.250}"
: "${NC_DOMAIN:=}"

printf '\033[1mTalk HPB health check\033[0m  (%s)\n' "$(hostname)"
info "domain=$NC_DOMAIN   caddy_internal_ip=$CADDY_IP"
if [ -z "$NC_DOMAIN" ]; then
  fail "NC_DOMAIN not set in $ENVFILE"
  exit 1
fi

APP=nextcloud-stack-nextcloud-app-1
SIGNALING=nextcloud-signaling
CADDY=nextcloud-caddy

# ---- 0. containers ---------------------------------------------------------
head1 "0. containers"
for c in "$APP" "$SIGNALING" "$CADDY" nextcloud-cron nextcloud-turn; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ]; then
    pass "$c is running"
  else
    fail "$c is NOT running  ->  docker compose up -d $c   (see runbook section 3)"
  fi
done

# ---- 1. Caddy must listen on :443 (the pin is useless without it) ----------
head1 "1. Caddy listeners (admin API is off, so a restart is the only reload)"
LISTEN="$(docker exec "$CADDY" sh -c 'netstat -tln 2>/dev/null | grep LISTEN' 2>/dev/null)"
for port in 80 443 8444; do
  # netstat columns are ":::80  :::*  LISTEN", so match the port followed by
  # whitespace - do NOT anchor to end of line.
  if printf '%s\n' "$LISTEN" | grep -qE ":${port}[[:space:]]"; then
    pass "Caddy listening on :$port"
  else
    fail "Caddy NOT listening on :$port"
    case $port in
      443) info "this is the 'Cannot connect to server' bug - see runbook F1" ;;
      80)  info "the public site is down" ;;
      8444) info "signaling cannot reach Nextcloud's OCS API (path 3)" ;;
    esac
  fi
done

# ---- 2. the domain pin -----------------------------------------------------
head1 "2. extra_hosts pin (containers must resolve the public domain to Caddy)"
for c in "$APP" nextcloud-cron "$SIGNALING"; do
  ip="$(docker exec "$c" getent hosts "$NC_DOMAIN" 2>/dev/null | awk '{print $1}')"
  if [ "$ip" = "$CADDY_IP" ]; then
    pass "$c resolves $NC_DOMAIN -> $ip"
  elif [ -z "$ip" ]; then
    fail "$c cannot resolve $NC_DOMAIN at all"
  else
    fail "$c resolves $NC_DOMAIN -> $ip (expected $CADDY_IP)"
    info "if the docker network was recreated, .env CADDY_INTERNAL_IP and the"
    info "ipv4_address in compose.yaml must agree - see runbook F7"
  fi
done

# ---- 3. path 2: app -> signaling back-channel over :443 ---------------------
head1 "3. path 2 - app -> Caddy :443 -> signaling (admin setup check uses this)"
WELCOME="$(docker exec nextcloud-cron curl -sSk -m 10 \
  "https://$NC_DOMAIN/standalone-signaling/api/v1/welcome" 2>/dev/null)"
if printf '%s' "$WELCOME" | grep -q '"nextcloud-spreed-signaling"'; then
  pass "welcome endpoint answers: $WELCOME"
else
  fail "welcome endpoint did not answer with JSON"
  info "got: ${WELCOME:-<empty>}"
  info "the spreed setup check calls this exact URL and reports"
  info "'Error: Cannot connect to server' when it fails - see runbook F1/F3"
fi

# ---- 4. the path matcher on both Caddy sites -------------------------------
head1 "4. path matcher - the bare WebSocket URL must reach signaling"
# The browser opens the REGISTERED url verbatim: /standalone-signaling, no
# trailing segment. A matcher of /standalone-signaling/* misses that and the
# request falls through to Nextcloud, which answers with its HTML 404 page.
# Signalling's own answer to an unauthenticated request is the plain text
# "404 page not found" - that is the signal we are looking for.
classify() { # $1 = label, $2 = body
  local label="$1" body="$2"
  if printf '%s' "$body" | grep -qi '<!DOCTYPE html>\|Nextcloud'; then
    fail "$label answered with Nextcloud HTML - path matcher bug (runbook F2)"
    info "got: ${body}"
  elif [ -n "$body" ]; then
    pass "$label reached the signaling server: ${body}"
  else
    fail "$label returned nothing (connection failed)"
  fi
}
# :80 is published to the host, so probe it from here.
B80="$(curl -s -m 8 -H "Host: $NC_DOMAIN" "http://127.0.0.1/standalone-signaling" 2>/dev/null | head -c 40)"
classify ":80  public site" "$B80"
# :443 is container-internal only, so probe it from a container.
B443="$(docker exec nextcloud-cron curl -sSk -m 8 \
  "https://$NC_DOMAIN/standalone-signaling" 2>/dev/null | head -c 40)"
classify ":443 internal site" "$B443"

# ---- 5. path 1: public site still healthy ----------------------------------
head1 "5. path 1 - public site through Caddy :80"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Host: $NC_DOMAIN" http://127.0.0.1/ 2>/dev/null)"
if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
  pass "public site returns $CODE"
else
  fail "public site returns $CODE"
  info "a 30x pointing at https:// means Caddy auto-redirected and Funnel will loop"
fi

# ---- 6. path 3: signaling -> Nextcloud capabilities ------------------------
head1 "6. path 3 - signaling -> Nextcloud OCS API (capabilities)"
REFS="$(docker logs --since 30m "$SIGNALING" 2>&1 | grep -c 'connection refused')"
if [ "$REFS" -eq 0 ]; then
  pass "no 'connection refused' from the signaling server in the last 30m"
else
  fail "'connection refused' seen $REFS time(s) in the last 30m"
  docker logs --since 30m "$SIGNALING" 2>&1 | grep 'connection refused' | tail -2 | sed 's/^/        /'
  info "the signaling server is trying a backend URL it cannot reach - see runbook F6"
fi

# ---- 7. registration -------------------------------------------------------
head1 "7. signaling registration (occ)"
if docker compose exec -T nextcloud-app php occ status 2>/dev/null | grep -q 'installed: true'; then
  OUT="$(docker compose exec -T nextcloud-app php occ talk:signaling:list 2>&1)"
  NSRV="$(printf '%s' "$OUT" | grep -c 'server: wss\?://')"
  if [ "$NSRV" = "1" ]; then
    pass "exactly one signaling server registered"
  elif [ "$NSRV" = "0" ]; then
    fail "no signaling server registered (Talk will fall back to internal signaling)"
  else
    fail "$NSRV signaling servers registered - duplicates (runbook F4)"
  fi
  if printf '%s' "$OUT" | grep -q 'verify: false'; then
    pass "verify: false (expected with the self-signed internal Caddy cert)"
  else
    warn "verify: true - only correct if Caddy serves a publicly trusted cert"
    info "with the tls internal listener this must be false, else the setup"
    info "check fails on certificate validation - see runbook F3"
  fi
  printf '%s\n' "$OUT" | sed 's/^/        /'
else
  fail "Nextcloud is not installed yet (occ status != installed: true)"
fi

# ---- 8. TURN ---------------------------------------------------------------
head1 "8. TURN"
for p in 3478/tcp 3478/udp; do
  if docker port nextcloud-turn "$p" 2>/dev/null | grep -q 3478; then
    pass "TURN $p published"
  else
    fail "TURN $p not published"
  fi
done

# ---- summary ---------------------------------------------------------------
head1 "result"
if [ "$FAIL" -eq 0 ]; then
  printf '  \033[32mAll checks passed.\033[0m\n\n'
else
  printf '  \033[31mSomething is broken - see the FAIL lines above and\033[0m\n'
  printf '  \033[31mTALK-HPB-RUNBOOK.md section 5 (troubleshooting).\033[0m\n\n'
fi
exit "$FAIL"
