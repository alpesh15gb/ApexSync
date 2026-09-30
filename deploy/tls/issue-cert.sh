#!/usr/bin/env bash
# Obtains the Let's Encrypt certificate for api.apexbooks.in.
#
# Run once on the server, as root. Safe to re-run: certbot is invoked with
# --keep-until-expiring, so a valid certificate is left alone.
#
# The chicken-and-egg this script exists to solve: nginx refuses to start when a
# vhost references a certificate file that does not exist, and a server that will
# not start cannot answer the ACME challenge that would create the certificate.
# So: stand up a temporary HTTP-only vhost, get the certificate, then swap in the
# real configuration.
#
#   ssh root@<server> 'bash -s' < deploy/tls/issue-cert.sh api.apexbooks.in you@apexbooks.in
set -euo pipefail

DOMAIN="${1:-api.apexbooks.in}"
EMAIL="${2:-}"

if [ -z "$EMAIL" ]; then
  echo "usage: $0 <domain> <email-for-expiry-notices>" >&2
  exit 64
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root (sudo $0 $*)" >&2
  exit 77
fi

# The script lives at server/deploy/tls/, so the repo root of the server
# directory is two levels up.
SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AVAILABLE=/etc/nginx/sites-available
ENABLED=/etc/nginx/sites-enabled
BOOTSTRAP="$AVAILABLE/atria-acme-bootstrap"

command -v certbot >/dev/null 2>&1 || {
  echo "certbot is not installed. On Ubuntu:" >&2
  echo "  apt-get update && apt-get install -y certbot" >&2
  exit 69
}

echo "==> 1/5  temporary HTTP-only vhost for $DOMAIN"
mkdir -p /var/www/html
cat > "$BOOTSTRAP" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type "text/plain";
    }

    location / { return 503; }
}
EOF
ln -sf "$BOOTSTRAP" "$ENABLED/atria-acme-bootstrap"

echo "==> 2/5  making sure the real site is off while the certificate is missing"
# If a previous run half-finished, the real site may be enabled and nginx dead.
rm -f "$ENABLED/$DOMAIN"
nginx -t
systemctl reload nginx || systemctl restart nginx

echo "==> 3/5  requesting the certificate"
certbot certonly --webroot -w /var/www/html -d "$DOMAIN" \
  --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring

echo "==> 4/5  enabling the real site"
rm -f "$ENABLED/atria-acme-bootstrap" "$BOOTSTRAP"
install -m 0644 "$SERVER_DIR/deploy/nginx/sites-available/$DOMAIN" "$AVAILABLE/$DOMAIN"
ln -sf "$AVAILABLE/$DOMAIN" "$ENABLED/$DOMAIN"
nginx -t
systemctl reload nginx

echo "==> 5/5  automatic renewal"
# certbot ships a systemd timer that tries twice a day. Without a deploy hook a
# renewal does nothing visible, because nginx cached the certificate it read at
# startup — this is the difference between "renewed" and "still serving the old
# one, until it expires".
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable --now certbot.timer 2>/dev/null || true

echo
echo "Done. Verify with:"
echo "  curl -fsS https://$DOMAIN/health"
echo "  curl -i  https://$DOMAIN/ready"
echo "  systemctl list-timers certbot.timer"
echo
echo "Try it before the API is running and you will get a 502 — that means TLS"
echo "is fine and only the upstream is missing."
