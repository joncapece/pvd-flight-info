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
