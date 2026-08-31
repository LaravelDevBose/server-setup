#!/usr/bin/env bash
# Copy the renewed Let's Encrypt certificate into Mailu and reload the front container.
#
# Install on the VPS:
#   cp certbot-deploy-hook.sh /etc/letsencrypt/renewal-hooks/deploy/mailu.sh
#   chmod +x /etc/letsencrypt/renewal-hooks/deploy/mailu.sh
#   /etc/letsencrypt/renewal-hooks/deploy/mailu.sh      # run once now
set -euo pipefail

MAIL_HOST="${MAIL_HOST:-mail.example.com}"
STACK_DIR="${STACK_DIR:-/opt/mail-server}"
CERT_DIR="${CERT_DIR:-/srv/mailu/certs}"

LIVE="/etc/letsencrypt/live/$MAIL_HOST"

install -m 644 "$LIVE/fullchain.pem" "$CERT_DIR/cert.pem"
install -m 600 "$LIVE/privkey.pem"   "$CERT_DIR/key.pem"

docker compose --project-directory "$STACK_DIR" restart front
echo "mailu: certificate for $MAIL_HOST deployed and front reloaded"
