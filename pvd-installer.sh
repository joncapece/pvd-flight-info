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
ALgBAA==
