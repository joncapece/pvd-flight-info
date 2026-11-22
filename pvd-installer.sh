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
h8/D5x/1+d+fWWpOAOABAA==
