#!/bin/bash
set -e

# Wait for Nextcloud to be ready
echo "Waiting for Nextcloud to be ready..."
until php /var/www/html/occ status > /dev/null 2>&1; do
    sleep 2
done

# Enable Talk app
echo "Enabling Talk app..."
php /var/www/html/occ app:enable talk

# Configure Talk
echo "Configuring Talk..."
php /var/www/html/occ config:system:set talk_turn_udp_enabled --value=true --type=bool
php /var/www/html/occ config:system:set talk_turn_tcp_enabled --value=true --type=bool

# Set TURN server settings
php /var/www/html/occ config:system:set talk_turn_stun_servers --value='["stun.l.google.com:19302"]' --type=string
php /var/www/html/occ config:system:set talk_turn_tls_port --value=443 --type=int

echo "Talk setup complete!"
exec "$@"
