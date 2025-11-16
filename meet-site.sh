#!/usr/bin/env bash
# meet-site.sh - Manage Nginx vhost + systemd unit for Jitsi (meet.funnelskingdom.com)
#
# Usage:
#   ./meet-site.sh deploy              # Write config, enable site, (optionally keep existing cert), reload nginx
#   ./meet-site.sh write-config        # Only (re)write the nginx site file
#   ./meet-site.sh enable              # Symlink site into sites-enabled
#   ./meet-site.sh cert                # Obtain/renew cert with certbot (webroot)
#   ./meet-site.sh selfsigned          # Generate a temporary self-signed cert
#   ./meet-site.sh reload              # nginx -t && reload
#   ./meet-site.sh status              # Show basic status (ports, files)
#   ./meet-site.sh systemd-install     # Create jitsi-stack systemd unit
#   ./meet-site.sh systemd-remove      # Remove jitsi-stack unit
#   ./meet-site.sh xmpp-users          # List registered XMPP users (prosody accounts)
#   ./meet-site.sh help                # Show help
#
# Idempotent: safe to re-run. Creates timestamped backup when overwriting vhost.
# Requires: bash, sudo (if not root), nginx, (optional) certbot for real certs.

set -euo pipefail

DOMAIN_DEFAULT="meet.funnelskingdom.com"
WEB_LOCAL_PORT_DEFAULT=8445          # Jitsi web container exposed localhost port
COLIBRI_HOST_PORT_DEFAULT=9091       # Host port mapped to JVB internal 8080 (colibri ws)
CERTBOT_WEBROOT="/var/www/certbot"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
SYSTEMD_UNIT_PATH="/etc/systemd/system/jitsi-stack.service"
JITSI_DIR="/opt/apps/jitsi"

# Allow overrides via env vars
DOMAIN="${DOMAIN:-$DOMAIN_DEFAULT}"
WEB_LOCAL_PORT="${WEB_LOCAL_PORT:-$WEB_LOCAL_PORT_DEFAULT}"
COLIBRI_HOST_PORT="${COLIBRI_HOST_PORT:-$COLIBRI_HOST_PORT_DEFAULT}"

VHOST_FILE="${NGINX_SITES_AVAILABLE}/${DOMAIN}"

as_root() {
  if [[ $EUID -ne 0 ]]; then sudo "$@"; else "$@"; fi
}

echo_err(){ echo >&2 "[ERR] $*"; }
echo_info(){ echo "[INFO] $*"; }
now_ts(){ date +%Y%m%d-%H%M%S; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo_err "Missing required command: $1"; exit 1; }; }

write_config(){
  need_cmd nginx
  as_root mkdir -p "$CERTBOT_WEBROOT"
  if [[ -f "$VHOST_FILE" ]]; then
    local backup="${VHOST_FILE}.bak-$(now_ts)"
    as_root cp "$VHOST_FILE" "$backup"
    echo_info "Existing vhost backed up to $backup"
  fi
  # Use single-quoted heredoc to avoid shell expansion of $ variables.
  as_root tee "$VHOST_FILE" > /dev/null <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name __DOMAIN__;

    # Expect certs here (real or self-signed)
    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy no-referrer;
    server_tokens off;

    proxy_buffering off;
    proxy_request_buffering off;
    client_max_body_size 0;

    location / {
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:__WEB_LOCAL_PORT__;
    }

    # XMPP WebSocket
    location /xmpp-websocket {
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:__WEB_LOCAL_PORT__/xmpp-websocket;
    }

    # BOSH (fallback)
    location /http-bind {
        proxy_read_timeout 3600s;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:__WEB_LOCAL_PORT__/http-bind;
    }

    # Colibri WebSocket (VideoBridge)
    location ^~ /colibri-ws/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:__COLIBRI_HOST_PORT__/colibri-ws/;
    }
}
EOF
  # Replace placeholders
  as_root sed -i "s/__DOMAIN__/${DOMAIN}/g" "$VHOST_FILE"
  as_root sed -i "s/__WEB_LOCAL_PORT__/${WEB_LOCAL_PORT}/g" "$VHOST_FILE"
  as_root sed -i "s/__COLIBRI_HOST_PORT__/${COLIBRI_HOST_PORT}/g" "$VHOST_FILE"
  echo_info "Vhost written: $VHOST_FILE"
}

enable_site(){
  as_root ln -sf "$VHOST_FILE" "${NGINX_SITES_ENABLED}/${DOMAIN}" || true
  echo_info "Site enabled (symlink created)."
}

reload_nginx(){
  as_root nginx -t
  as_root systemctl reload nginx
  echo_info "Nginx reloaded."
}

obtain_cert(){
  need_cmd certbot
  need_cmd nginx
  as_root mkdir -p "$CERTBOT_WEBROOT"
  # Use webroot so we don't have to stop nginx
  as_root certbot certonly --agree-tos --no-eff-email --register-unsafely-without-email \
    --webroot -w "$CERTBOT_WEBROOT" -d "$DOMAIN" || {
      echo_err "Certbot failed"; exit 1;
    }
  echo_info "Certificate obtained for $DOMAIN"
}

self_signed(){
  local live_dir="/etc/letsencrypt/live/${DOMAIN}"
  as_root mkdir -p "$live_dir"
  if [[ -f "$live_dir/privkey.pem" ]]; then
    echo_info "Existing key present; leaving in place (self-signed skipped)."
    return 0
  fi
  echo_info "Generating temporary self-signed cert (NOT trusted).";
  as_root openssl req -x509 -nodes -newkey rsa:2048 -days 10 \
    -keyout "$live_dir/privkey.pem" -out "$live_dir/fullchain.pem" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  echo_info "Self-signed certificate generated (valid 10 days).";
}

status(){
  echo "--- STATUS ---"
  echo "Domain:           $DOMAIN"
  echo "Vhost file:       $VHOST_FILE (exists: $( [[ -f $VHOST_FILE ]] && echo yes || echo no ))"
  echo "Enabled symlink:  ${NGINX_SITES_ENABLED}/${DOMAIN} (exists: $( [[ -f ${NGINX_SITES_ENABLED}/${DOMAIN} ]] && echo yes || echo no ))"
  echo "Cert live dir:    /etc/letsencrypt/live/${DOMAIN}"
  echo "Web local port:   $WEB_LOCAL_PORT"
  echo "Colibri host port:$COLIBRI_HOST_PORT"
  echo "Listening (netstat/ss):"
  ss -ltn '( sport = :80 or sport = :443 )' 2>/dev/null || true
  echo "Containers:"; docker ps --format 'table {{.Names}}\t{{.Status}}' | grep jitsi || true
}

systemd_install(){
  if [[ -f $SYSTEMD_UNIT_PATH ]]; then
    echo_info "Systemd unit already exists: $SYSTEMD_UNIT_PATH"
    return 0
  fi
  as_root tee "$SYSTEMD_UNIT_PATH" > /dev/null <<EOF
[Unit]
Description=Jitsi + Jibri (docker compose)
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${JITSI_DIR}
ExecStart=/usr/bin/docker compose -f docker-compose.yml -f jitsi.ports.override.yml up -d web prosody jicofo jvb
ExecStartPost=/usr/bin/docker compose -f docker-compose.yml -f jitsi.ports.override.yml -f jibri.override.yml up -d jibri
ExecStop=/usr/bin/docker compose -f docker-compose.yml -f jitsi.ports.override.yml -f jibri.override.yml down
RemainAfterExit=yes
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
  as_root systemctl daemon-reload
  as_root systemctl enable jitsi-stack
  echo_info "Systemd unit installed & enabled."
}

systemd_remove(){
  if [[ -f $SYSTEMD_UNIT_PATH ]]; then
    as_root systemctl disable --now jitsi-stack || true
    as_root rm -f "$SYSTEMD_UNIT_PATH"
    as_root systemctl daemon-reload
    echo_info "Systemd unit removed."
  else
    echo_info "Systemd unit not present."
  fi
}

usage(){ sed -n '1,40p' "$0" | grep -E "^# |^#"; }

# List XMPP users (workaround for 'luarocks not found' noise by filtering output)
xmpp_users(){
  echo "[INFO] Attempting to list users via prosodyctl (ignoring luarocks warning)"
  if docker ps --format '{{.Names}}' | grep -q '^jitsi-prosody-1$'; then
    # prosodyctl list sometimes emits a luarocks warning; filter only user@domain lines
    docker exec jitsi-prosody-1 prosodyctl --config /config/prosody.cfg.lua list 2>/dev/null | \
      grep -E '^[A-Za-z0-9_.+-]+@' || true
  else
    echo "[WARN] prosody container not found; attempting filesystem scan"
  fi
  echo "[INFO] Filesystem accounts (dat files):"
  find "$HOME/.jitsi-meet-cfg/prosody/config/data" -type f -path '*/accounts/*' -name '*.dat' 2>/dev/null | \
    sed 's#.*/accounts/##; s/\.dat$//' || true
}

deploy(){
  write_config
  enable_site
  # If no cert, try to get one; fallback to self-signed
  if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    if command -v certbot >/dev/null 2>&1; then
      echo_info "Attempting real certificate issuance..."
      if obtain_cert; then
        echo_info "Real certificate installed."
      else
        echo_err "Real cert failed; generating self-signed."
        self_signed
      fi
    else
      echo_info "certbot not available; creating self-signed cert."
      self_signed
    fi
  else
    echo_info "Certificate already exists; skipping issuance."
  fi
  reload_nginx
  status
}

cmd="${1:-help}"
shift || true
case "$cmd" in
  write-config) write_config ;;
  enable) enable_site ;;
  reload) reload_nginx ;;
  cert) obtain_cert ; reload_nginx ;;
  selfsigned) self_signed ; reload_nginx ;;
  status) status ;;
  systemd-install) systemd_install ;;
  systemd-remove) systemd_remove ;;
  xmpp-users) xmpp_users ;;
  deploy) deploy ;;
  help|*) usage ;;
 esac
