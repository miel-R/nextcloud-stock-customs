#!/bin/bash
# Quick recovery after internet restart
# Run: /home/mis/quick-recovery.sh

set -e

echo "=== Quick Recovery After Internet Restart ==="

# 1. Ensure Tailscale is up
echo "1. Checking Tailscale..."
tailscale status --json | jq -r '.BackendState' | grep -q Running || {
    echo "   Tailscale down, bringing up..."
    sudo tailscale up
    sleep 3
}

# 2. Restart Funnel
echo "2. Restarting Tailscale Funnel..."
tailscale funnel stop 2>/dev/null || true
tailscale funnel --bg http://127.0.0.1:80
sleep 5

# 3. Verify public domain resolves to Caddy internal IP from signaling
echo "3. Verifying DNS resolution from signaling container..."
PUBLIC_IP=$(docker compose -f /home/mis/docker/nextcloud-stock-customs/compose.yaml exec -T signaling getent hosts mis-server.tail204a2d.ts.net | awk '{print $1}')
echo "   Resolved to: $PUBLIC_IP"
if [[ "$PUBLIC_IP" != "172.18.0.250" ]]; then
    echo "   WARNING: Expected 172.18.0.250, got $PUBLIC_IP"
fi

# 4. Restart critical services
echo "4. Restarting signaling, nextcloud-app, nextcloud-cron..."
cd /home/mis/docker/nextcloud-stock-customs
docker compose restart signaling nextcloud-app nextcloud-cron
sleep 10

# 5. Verify signaling fetched capabilities
echo "5. Verifying signaling capabilities fetch..."
docker compose logs signaling --tail 20 | grep -q "Received capabilities" && \
    echo "   OK: Capabilities fetched successfully" || \
    echo "   WARNING: Capabilities not yet fetched (check logs)"

# 6. Verify Talk signaling
echo "6. Verifying Talk signaling registration..."
docker compose exec -u www-data nextcloud-app php occ talk:signaling:list

echo "=== Recovery Complete ==="
echo "Clear browser cache and test Nextcloud Talk."
