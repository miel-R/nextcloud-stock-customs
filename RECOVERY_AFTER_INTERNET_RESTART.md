# Recovery Procedure After Internet Restart / Tailscale Funnel Disconnect

## What Happens
When internet restarts:
1. Tailscale Funnel disconnects → public domain becomes unreachable
2. Public IP may change → Tailscale MagicDNS updates, but DNS propagation takes time
3. Containers may lose connectivity to external services

## Quick Recovery Steps (Run in Order)

### 1. Wait for Tailscale to Reconnect
```bash
# Check Tailscale status
tailscale status

# If not connected, bring it up
sudo tailscale up
```

### 2. Verify Public Domain Resolution
```bash
# Should resolve to your Tailscale IP (100.x.x.x)
dig +short mis-server.tail204a2d.ts.net

# Or use tailscale to check
tailscale status --json | jq -r '.Self.TailscaleIPs[0]'
```

### 3. Restart Funnel
```bash
# Kill existing funnel
tailscale funnel stop

# Restart funnel pointing to local Caddy
tailscale funnel --bg http://127.0.0.1:80
```

### 4. Verify Containers Can Reach Public Domain
```bash
# Test from signaling container (needs public domain for capabilities)
docker compose exec signaling getent hosts mis-server.tail204a2d.ts.net

# Should return Caddy's internal IP (172.18.0.250)
```

### 5. Restart Affected Services
```bash
cd /home/mis/docker/nextcloud-stock-customs

# Restart signaling (fetches capabilities on startup)
docker compose restart signaling

# Restart nextcloud-app and cron (they use extra_hosts for back-channel)
docker compose restart nextcloud-app nextcloud-cron
```

### 6. Verify Health
```bash
# Check signaling logs - should fetch capabilities successfully
docker compose logs signaling --tail 30 | grep "Received capabilities"

# Check Nextcloud status
docker compose exec -u www-data nextcloud-app php occ status

# Verify Talk signaling still registered
docker compose exec -u www-data nextcloud-app php occ talk:signaling:list
```

## If Public IP Changed (New Tailscale MagicDNS)

If `tailscale status` shows a **different** `.ts.net` hostname:

### Option A: Update DNS + Restart (if using custom domain)
```bash
# 1. Update your DNS provider (Cloudflare, etc.) to new IP
# 2. Update .env
NC_DOMAIN=new-hostname.ts.net
# 3. Update NEXTCLOUD_TRUSTED_DOMAINS
# 4. Update OVERWRITECLIURL
# 5. Recreate containers
docker compose up -d --force-recreate
```

### Option B: Just Use New .ts.net Hostname (Tailscale MagicDNS)
```bash
# Get new hostname
tailscale status

# Update .env with new hostname
NC_DOMAIN=new-hostname.ts.net
NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1 nextcloud new-hostname.ts.net nextcloud-caddy
OVERWRITECLIURL=https://new-hostname.ts.net

# Re-register Talk signaling
docker compose exec -u www-data nextcloud-app php occ talk:signaling:delete "wss://OLD_HOSTNAME/standalone-signaling"
docker compose exec -u www-data nextcloud-app php occ talk:signaling:add "wss://new-hostname.ts.net/standalone-signaling" "SECRET" --verify

# Re-register TURN
docker compose exec -u www-data nextcloud-app php occ talk:turn:delete
docker compose exec -u www-data nextcloud-app php occ talk:turn:add turn new-hostname.ts.net udp,tcp --secret=SECRET

# Recreate containers
docker compose up -d --force-recreate
```

## Preventive: Auto-Recovery Script

Create `/home/mis/recovery.sh`:
```bash
#!/bin/bash
set -e

echo "=== Post-internet-restart recovery ==="

# 1. Wait for Tailscale
echo "Waiting for Tailscale..."
until tailscale status --json | jq -e '.BackendState == "Running"' >/dev/null 2>&1; do
    sleep 2
done

# 2. Restart funnel
echo "Restarting Tailscale Funnel..."
tailscale funnel stop 2>/dev/null || true
tailscale funnel --bg http://127.0.0.1:80

# 3. Wait for DNS propagation
echo "Waiting for DNS..."
sleep 10

# 4. Restart stack services
cd /home/mis/docker/nextcloud-stock-customs
docker compose restart signaling nextcloud-app nextcloud-cron

echo "=== Recovery complete ==="
```
```bash
chmod +x /home/mis/recovery.sh
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `context deadline exceeded` fetching capabilities | Public domain not resolving to Caddy | Check `extra_hosts` in compose.yaml, restart signaling |
| `invalid_token` in Talk | hello-v2-token-key not fetched | Restart signaling after DNS works |
| `403 Forbidden` on signaling | Backend URL mismatch | Ensure SIGNALING_BACKEND_URL has BOTH public + internal URLs |
| Nextcloud shows "trusted domain" error | NC_DOMAIN changed | Update .env trusted_domains, recreate app container |
---

## n8n Recovery After Internet Restart

### n8n Not Accessible After Internet Restart

**Symptoms**: n8n editor not loading, connection refused, or "n8n not working"

**Root Causes**:
1. Caddy n8n routing not enabled (N8N_DOMAIN not set in .env)
2. Tailscale Funnel not restarted for n8n hostname
3. n8n container not running or database connection failed
4. N8N_BIND port conflict (port 5678/5679 already in use)

**Recovery Steps**:

#### 1. Verify n8n Container Running
```bash
docker compose -f /home/mis/docker/nextcloud-stock-customs/compose.n8n.yaml ps
docker compose -f /home/mis/docker/nextcloud-stock-customs/compose.n8n.yaml logs n8n --tail 20
```

#### 2. Test Internal Access (bypass Caddy)
```bash
# n8n binds to N8N_BIND (default 127.0.0.1:5679)
curl -fsS http://127.0.0.1:5679 | head -5
```
If this works but external doesn't → Caddy routing issue.

#### 3. Check N8N_DOMAIN in .env (REQUIRED for Caddy routing)
```bash
grep N8N_DOMAIN /home/mis/docker/nextcloud-stock-customs/.env
```
**Must be set** for Caddy to route n8n traffic. Example:
```
N8N_DOMAIN=n8n.mis-server.tail204a2d.ts.net
```

#### 4. Restart Caddy After N8N_DOMAIN Change
```bash
cd /home/mis/docker/nextcloud-stock-customs && docker compose restart caddy
```

#### 5. Verify Funnel for n8n Hostname (if using separate subdomain)
```bash
# If N8N_DOMAIN is a different subdomain, need separate Funnel:
tailscale funnel --bg --https=8443 http://127.0.0.1:5679
```
Or add to existing Funnel if same hostname:
```bash
tailscale funnel --bg http://127.0.0.1:80  # serves both Nextcloud + n8n
```

#### 6. Common Fix: N8N_BIND Port Conflict
If port 5678/5679 is in use:
```bash
# Check what's using the port
sudo ss -tlnp | grep :567

# Change N8N_BIND in .env to free port
N8N_BIND=127.0.0.1:5680

# Restart n8n
docker compose -f compose.n8n.yaml restart n8n
```

#### 7. Database Connection Issues
```bash
# Check n8n can reach Postgres
docker compose -f compose.n8n.yaml exec n8n pg_isready -h postgres-db -p 5432

# Check n8n database exists
docker compose -f compose.db.yaml exec postgres-db psql -U nextcloud -d n8n -c "\dt"
```

---

### Quick n8n Recovery Script
```bash
#!/bin/bash
cd /home/mis/docker/nextcloud-stock-customs

# 1. Restart Caddy (routing)
docker compose restart caddy

# 2. Restart n8n
docker compose -f compose.n8n.yaml restart n8n

# 3. Verify
sleep 5
curl -fsS http://127.0.0.1:5679 >/dev/null && echo "n8n OK" || echo "n8n FAILED"
```
