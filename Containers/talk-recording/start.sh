#!/bin/bash
set -e

# Wait for Nextcloud to be ready
echo 
Waiting
for
Nextcloud
to
be
ready...
until php /var/www/html/occ status > /dev/null 2>&1; do
    sleep 2
done

# Enable Talk recording app
echo Enabling
Talk
recording
app...
php /var/www/html/occ app:enable talk_recording

echo Talk
recording
setup
complete!
exec \\$@\
