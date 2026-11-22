#!/usr/bin/env bash
#
# PVD Flight Information System: installer for a DigitalOcean droplet (Ubuntu 22.04 or 24.04).
#
# Run from the droplet's web console (logged in as root). Paste this file with:
#   nano install.sh      (paste, then Ctrl+O, Enter, Ctrl+X)
#   REPO_URL=https://github.com/you/pvd-flight-info.git bash install.sh
#
# Source of the code (first install). Pick one:
#   (none)      the bundled installer (pvd-installer.sh, built by deploy/make-bundle.sh) carries the app inside it
#   REPO_URL=https://github.com/you/pvd-flight-info.git   git repo (for a private repo, use https://USER:TOKEN@github.com/...)
#   ARCHIVE_URL=https://example.com/pvd-flight-info.tar.gz  tarball of the project
#
# Optional settings (all as environment variables):
#   DOMAIN=fids.example.com          public hostname; the DNS A record must already point at this droplet
#   LETSENCRYPT_EMAIL=ops@example.com  enables a free HTTPS certificate for DOMAIN
#   ADMIN_TOKEN=...                  admin password; generated when omitted
#   ADMIN_ALLOW_CIDR="203.0.113.0/24 198.51.100.7"  only these addresses may reach /admin
#   FEED_POLL_SECONDS=60
#   OAG_API_KEY, OAG_BASE_URL, OAG_PATH   enable the licensed OAG feed (default: sample data)
#
# Safe to re-run. A re-run updates the code, keeps the data and the admin token, and restarts the service.
set -Eeuo pipefail

APP_NAME="pvd-flight-info"
APP_USER="pvdfi"
APP_DIR="/opt/${APP_NAME}"
CONF_DIR="/etc/${APP_NAME}"
ENV_FILE="${CONF_DIR}/env"
DATA_DIR="/var/lib/${APP_NAME}"
SERVICE="${APP_NAME}"
NGINX_SITE="/etc/nginx/sites-available/${APP_NAME}"
PORT="${PORT:-8080}"
PAYLOAD_MARK="__PVD_PAYLOAD__"   # make-bundle.sh appends the project after this line
NODE_MIN_MAJOR=18
NODE_MAJOR_TO_INSTALL=20

REPO_URL="${REPO_URL:-}"
ARCHIVE_URL="${ARCHIVE_URL:-}"
DOMAIN="${DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
ADMIN_TOKEN="${ADMIN_TOKEN:-}"
ADMIN_ALLOW_CIDR="${ADMIN_ALLOW_CIDR:-}"
FEED_POLL_SECONDS="${FEED_POLL_SECONDS:-60}"
OAG_API_KEY="${OAG_API_KEY:-}"
OAG_BASE_URL="${OAG_BASE_URL:-}"
OAG_PATH="${OAG_PATH:-}"

log()  { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "install stopped at line ${LINENO} (exit code $?). Fix the cause above and run the script again; re-running is safe."' ERR

# ---- Pre-flight ------------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "run as root. In the droplet console you are root already; otherwise use: sudo -E bash install.sh"
[[ -r /etc/os-release ]] || die "cannot read /etc/os-release; this script needs Ubuntu or Debian"
. /etc/os-release
case "${ID}:${VERSION_ID}" in
  ubuntu:22.04|ubuntu:24.04|debian:12) ;;
  *) info "Warning: tested on Ubuntu 22.04 and 24.04; detected ${PRETTY_NAME}. Continuing." ;;
esac

if [[ -n "$DOMAIN" && ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
  die "DOMAIN '${DOMAIN}' does not look like a hostname (example: fids.example.com)"
fi
if [[ -n "$LETSENCRYPT_EMAIL" && -z "$DOMAIN" ]]; then
  die "LETSENCRYPT_EMAIL needs DOMAIN as well"
fi

export DEBIAN_FRONTEND=noninteractive
export GIT_TERMINAL_PROMPT=0   # fail fast instead of waiting for a git password in the console

# ---- System packages -------------------------------------------------------------------------

log "Installing system packages"
apt-get update -y
apt-get install -y ca-certificates curl git tar openssl nginx ufw

# ---- Node.js ---------------------------------------------------------------------------------

log "Checking Node.js"
node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }
if [[ "$(node_major)" -lt "$NODE_MIN_MAJOR" ]]; then
  info "Installing Node.js ${NODE_MAJOR_TO_INSTALL} from NodeSource"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR_TO_INSTALL}.x" | bash -
  apt-get install -y nodejs
fi
info "node $(node --version), npm $(npm --version 2>/dev/null || echo n/a)"

# ---- Service user and directories ------------------------------------------------------------

log "Preparing service user and directories"
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$APP_USER"
install -d -m 755 "$CONF_DIR"
install -d -m 750 -o "$APP_USER" -g "$APP_USER" "$DATA_DIR"

# ---- Application code ------------------------------------------------------------------------

log "Fetching application code"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC=""

if [[ -n "$REPO_URL" ]]; then
  info "cloning ${REPO_URL%%@*}"
  git clone --depth 1 "$REPO_URL" "$TMP/repo"
  SRC="$TMP/repo"
elif [[ -n "$ARCHIVE_URL" ]] || grep -q "^${PAYLOAD_MARK}\$" "$0" 2>/dev/null; then
  mkdir "$TMP/archive"
  if [[ -n "$ARCHIVE_URL" ]]; then
    info "downloading archive"
    curl -fsSL "$ARCHIVE_URL" -o "$TMP/app.tar.gz"
  else
    info "unpacking the application bundled in this installer"
    sed -n "/^${PAYLOAD_MARK}\$/,\$p" "$0" | sed '1d' | base64 -d > "$TMP/app.tar.gz"
  fi
  tar -xzf "$TMP/app.tar.gz" -C "$TMP/archive"
  PKG="$(find "$TMP/archive" -maxdepth 2 -name package.json -print -quit)"
  [[ -n "$PKG" ]] || die "the archive does not contain package.json"
  SRC="$(dirname "$PKG")"
elif [[ -f "$APP_DIR/package.json" ]]; then
  info "no REPO_URL or ARCHIVE_URL given: keeping the code already in ${APP_DIR}"
else
  die "no source for the code. Set REPO_URL (git) or ARCHIVE_URL (.tar.gz) and run the script again."
fi

if [[ -n "$SRC" ]]; then
  [[ -f "$SRC/package.json" && -f "$SRC/src/server.js" ]] || die "the source does not look like the PVD flight information app"
  rm -rf "$APP_DIR.new"
  mkdir -p "$APP_DIR.new"
  cp -a "$SRC"/. "$APP_DIR.new"/
  rm -rf "$APP_DIR.new/.git" "$APP_DIR.new/data"
  rm -rf "$APP_DIR"
  mv "$APP_DIR.new" "$APP_DIR"
fi

chown -R root:root "$APP_DIR"
chmod -R a+rX "$APP_DIR"

log "Running the test suite"
(cd "$APP_DIR" && node --test >/dev/null) || die "tests failed in ${APP_DIR}; the code was not started"
info "all tests passed"

# ---- Configuration ---------------------------------------------------------------------------

log "Writing configuration"
if [[ -z "$ADMIN_TOKEN" && -f "$ENV_FILE" ]]; then
  ADMIN_TOKEN="$(grep -m1 '^ADMIN_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)"
fi
TOKEN_IS_NEW=0
if [[ -z "$ADMIN_TOKEN" ]]; then
  ADMIN_TOKEN="$(openssl rand -hex 24)"
  TOKEN_IS_NEW=1
fi

{
  echo "# Managed by install.sh. Edit this file, then run: systemctl restart ${SERVICE}"
  echo "NODE_ENV=production"
  echo "HOST=127.0.0.1"
  echo "PORT=${PORT}"
  echo "ADMIN_TOKEN=${ADMIN_TOKEN}"
  echo "DATA_FILE=${DATA_DIR}/store.json"
  echo "FEED_POLL_SECONDS=${FEED_POLL_SECONDS}"
  [[ -n "$OAG_API_KEY"  ]] && echo "OAG_API_KEY=${OAG_API_KEY}"
  [[ -n "$OAG_BASE_URL" ]] && echo "OAG_BASE_URL=${OAG_BASE_URL}"
  [[ -n "$OAG_PATH"     ]] && echo "OAG_PATH=${OAG_PATH}"
} > "${ENV_FILE}.new"
chown root:"$APP_USER" "${ENV_FILE}.new"
chmod 640 "${ENV_FILE}.new"
mv "${ENV_FILE}.new" "$ENV_FILE"

# ---- systemd service -------------------------------------------------------------------------

log "Installing the systemd service"
NODE_BIN="$(command -v node)"
cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=PVD Flight Information System (FIDS, GIDS, bag claim)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} src/server.js
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# ---- nginx reverse proxy ---------------------------------------------------------------------

log "Configuring nginx"
PROXY_BLOCK="        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;"

ADMIN_RESTRICT=""
if [[ -n "$ADMIN_ALLOW_CIDR" ]]; then
  for ip in $ADMIN_ALLOW_CIDR; do
    ADMIN_RESTRICT+="        allow ${ip};"$'\n'
  done
  ADMIN_RESTRICT+="        deny all;"$'\n'
else
  info "WARNING: /admin is reachable from any address. Set ADMIN_ALLOW_CIDR to restrict it."
fi

SERVER_NAME="${DOMAIN:-_}"
cat > "$NGINX_SITE" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${SERVER_NAME};
    client_max_body_size 100k;

    # Admin portal and admin API: optionally limited to specific addresses.
    location ~ ^/(admin|api/admin) {
${ADMIN_RESTRICT}${PROXY_BLOCK}
    }

    location / {
${PROXY_BLOCK}
    }
}
EOF
ln -sf "$NGINX_SITE" "/etc/nginx/sites-enabled/${APP_NAME}"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx >/dev/null
systemctl reload nginx || systemctl restart nginx

# ---- Firewall --------------------------------------------------------------------------------

log "Configuring the firewall (SSH, HTTP, HTTPS only)"
ufw allow OpenSSH >/dev/null
ufw allow 'Nginx Full' >/dev/null
ufw --force enable >/dev/null
ufw status | sed 's/^/    /'

# ---- HTTPS (optional) ------------------------------------------------------------------------

if [[ -n "$DOMAIN" && -n "$LETSENCRYPT_EMAIL" ]]; then
  log "Requesting an HTTPS certificate for ${DOMAIN}"
  apt-get install -y certbot python3-certbot-nginx
  if certbot --nginx -d "$DOMAIN" -m "$LETSENCRYPT_EMAIL" --agree-tos --non-interactive --redirect; then
    info "HTTPS is enabled and renews automatically"
  else
    info "WARNING: certificate request failed. Check that ${DOMAIN} points at this droplet, then run:"
    info "  certbot --nginx -d ${DOMAIN} -m ${LETSENCRYPT_EMAIL} --agree-tos --redirect"
  fi
fi

# ---- Start and verify ------------------------------------------------------------------------

log "Starting the service"
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"

ok=0
for _ in $(seq 1 20); do
  if curl -fsS "http://127.0.0.1:${PORT}/api/flights?dir=D" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 1
done
[[ "$ok" == 1 ]] || die "the service did not answer on port ${PORT}. See: journalctl -u ${SERVICE} -n 50 --no-pager"

PUBLIC_IP="$(curl -fsS4 --max-time 5 https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')"
BASE_URL="http://${PUBLIC_IP}"
if [[ -n "$DOMAIN" ]]; then
  BASE_URL="https://${DOMAIN}"
  [[ -n "$LETSENCRYPT_EMAIL" ]] || BASE_URL="http://${DOMAIN}"
fi

cat <<EOF

============================================================
 PVD Flight Information System is running.

 Departures board:  ${BASE_URL}/fids
 Arrivals board:    ${BASE_URL}/fids?dir=A
 Gate display:      ${BASE_URL}/gids?gate=A1
 Baggage claim:     ${BASE_URL}/bags
 Admin portal:      ${BASE_URL}/admin
EOF
if [[ "$TOKEN_IS_NEW" == 1 ]]; then
  cat <<EOF

 Admin token (save it now; it is also stored in ${ENV_FILE}):
   ${ADMIN_TOKEN}
EOF
else
  cat <<EOF

 Admin token: unchanged (stored in ${ENV_FILE})
EOF
fi
cat <<EOF

 Useful commands:
   systemctl status ${SERVICE}          service status
   journalctl -u ${SERVICE} -f          live logs
   cp ${DATA_DIR}/store.json ~/        back up overrides, manual flights, and the audit log
   bash install.sh                      re-run to update the code (keeps data and token)
============================================================
EOF

exit 0
__PVD_PAYLOAD__
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
+PwRz/8PHmxcIwC4AQA=
