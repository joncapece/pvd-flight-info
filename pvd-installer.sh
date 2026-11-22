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
18/Xz9fPv9rn/weUhUZBAOABAA==
