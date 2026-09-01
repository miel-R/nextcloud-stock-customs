#!/bin/bash
set -e

# Wait for Nextcloud to be ready
echo "Waiting for Nextcloud to be ready..."
until php /var/www/html/occ status > /dev/null 2>&1; do
    sleep 2
done

# Enable AMI bot
echo "Enabling AMI bot..."
php /var/www/html/occ app:enable ami_bot

# Configure AMI bot
echo "Configuring AMI bot..."
php /var/www/html/occ config:system:set ami_bot_allowed_user --value="" --type=string

echo "AMI bot setup complete!"
exec "$@"
