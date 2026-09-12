#!/usr/bin/env bash
# ============================================================================
#  apps/marzban/setup.sh — make the Marzban panel usable on this node.
#
#  Marzban runs from the official image through docker compose (the upstream
#  compose file already uses network_mode: host, so the dashboard listens on the
#  node itself). This script is idempotent: it prepares the compose file, the
#  .env with the operator credentials, and makes sure the image is present.
#
#  What is persistent and where:
#    /var/lib/marzban  sqlite database, xray config, certificates  -> data_paths
#    /opt/marzban      docker-compose.yml, .env, admin password    -> config_paths
#  Both are age-encrypted into the memory repository and restored before this
#  script runs, so the panel URL, its data and its credentials survive every
#  handover.
# ============================================================================
export LOG_TAG=marzban
. "$(dirname "$0")/../../scripts/lib/common.sh"
load_config

DIR=/opt/marzban
DATA=/var/lib/marzban
ADMIN_USER="${MARZBAN_ADMIN_USER:-admin}"
PW_FILE="$DIR/.admin-password"

# ---- credentials ----------------------------------------------------------
# One password for the whole node: the operator already knows it (it is the ssh
# password), so the dashboard never needs a second secret to remember.
WANT_PW="${OPERATOR_PASSWORD:-${MARZBAN_ADMIN_PASSWORD:-}}"
PW_FILE_PRE="$DIR/.admin-password"

realign_password() {
  [ -n "$WANT_PW" ] || return 0
  [ -f "$PW_FILE_PRE" ] || return 0
  [ "$(sudo cat "$PW_FILE_PRE" 2>/dev/null)" = "$WANT_PW" ] && return 0
  printf '%s' "$WANT_PW" | sudo tee "$PW_FILE_PRE" >/dev/null
  sudo chmod 600 "$PW_FILE_PRE"
  log "panel password realigned with the operator password"
  bash "$(dirname "$0")/ensure-admin.sh" "$WANT_PW" || warn "could not realign the dashboard password"
}

# Fast path — after a handover the restored data usually comes back with a
# container that is already healthy; touching anything would only cost minutes.
# The credentials are still checked (cheap) so a rotated operator password
# reaches the dashboard on the next boot.
if curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:8000/dashboard/"; then
  realign_password
  log "dashboard already answering on 127.0.0.1:8000 — nothing else to do"
  exit 0
fi

step "marzban prerequisites"
if ! have docker; then
  log "installing docker"
  retry 2 3 bash -c 'apt-get update -qq && apt-get install -y -qq docker.io docker-compose-v2' >/dev/null 2>&1 \
    || die "cannot install docker"
  systemctl enable --now docker >/dev/null 2>&1 || true
fi
have docker || die "docker is required for marzban"

step "compose file + credentials"
sudo mkdir -p "$DIR" "$DATA"
if [ ! -s "$DIR/docker-compose.yml" ]; then
  sudo curl -fsSL -o "$DIR/docker-compose.yml" \
    https://github.com/Gozargah/Marzban/raw/master/docker-compose.yml || die "cannot fetch docker-compose.yml"
fi

admin_pw=""
if [ -s "$PW_FILE" ] && [ -n "$WANT_PW" ] && [ "$(sudo cat "$PW_FILE")" != "$WANT_PW" ]; then
  admin_pw="$WANT_PW"
  printf '%s' "$admin_pw" | sudo tee "$PW_FILE" >/dev/null
  sudo chmod 600 "$PW_FILE"
  log "panel password realigned with the operator password"
  bash "$(dirname "$0")/ensure-admin.sh" "$WANT_PW" || warn "could not realign the dashboard password"
elif [ -s "$PW_FILE" ]; then
  admin_pw="$(sudo cat "$PW_FILE")"
  log "reusing the existing operator password"
elif [ -n "$WANT_PW" ]; then
  admin_pw="$WANT_PW"
  printf '%s' "$admin_pw" | sudo tee "$PW_FILE" >/dev/null
  sudo chmod 600 "$PW_FILE"
  log "adopted the operator password"
else
  # plain `tr </dev/urandom | head` dies of SIGPIPE under `set -o pipefail`
  admin_pw="$(openssl rand -hex 16)"
  printf '%s' "$admin_pw" | sudo tee "$PW_FILE" >/dev/null
  sudo chmod 600 "$PW_FILE"
  log "generated a new operator password (stored 0600, printed by node-panels)"
fi

# .env is regenerated from the current template only when it is missing, so a
# restored .env (which may carry extra operator settings) always wins
if [ ! -s "$DIR/.env" ]; then
  jwt="$(openssl rand -hex 32)"
  sudo tee "$DIR/.env" >/dev/null <<ENV
UVICORN_HOST = "0.0.0.0"
UVICORN_PORT = 8000
UVICORN_SSL_CERTFILE = ""
UVICORN_SSL_KEYFILE = ""
SUDO_USERNAME = "$ADMIN_USER"
SUDO_PASSWORD = "$admin_pw"
SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"
XRAY_JSON = "/var/lib/marzban/xray_config.json"
XRAY_SUBSCRIPTION_URL_PREFIX = ""
XRAY_SUBSCRIPTION_PATH = "sub"
JWT_ACCESS_TOKEN_EXPIRE_MINUTES = 1440
DOCS = true
ENV
  log "wrote $DIR/.env (tailnet-only dashboard on 8000)"
fi
sudo chmod 600 "$DIR/.env"

# The container refuses to start without an xray config, and the official
# installer fetches exactly this file on a fresh machine — so do the same, once.
if [ ! -s "$DATA/xray_config.json" ]; then
  sudo curl -fsSL -o "$DATA/xray_config.json" \
    https://raw.githubusercontent.com/Gozargah/Marzban/master/xray_config.json \
    || die "cannot fetch the default xray_config.json"
  sudo chmod 644 "$DATA/xray_config.json"
  log "installed the default xray configuration"
fi

step "image + first start"
if ! sudo docker image inspect gozargah/marzban:latest >/dev/null 2>&1; then
  sudo docker compose -f "$DIR/docker-compose.yml" pull --quiet >/dev/null 2>&1 \
    || warn "image pull failed (will retry at start)"
fi
sudo docker compose -f "$DIR/docker-compose.yml" up -d --no-build >/dev/null 2>&1 \
  || die "docker compose up failed"

step "operator account"
if [ -n "$WANT_PW" ]; then
  bash "$(dirname "$0")/ensure-admin.sh" "$WANT_PW" || warn "could not prepare the dashboard admin"
fi

step "waiting for the dashboard"
if wait_http "http://127.0.0.1:8000/dashboard/" 90 200; then
  log "marzban dashboard is answering on 127.0.0.1:8000"
else
  warn "dashboard did not answer within 90s — inspect: docker compose -f $DIR/docker-compose.yml logs --tail=40"
fi
log "marzban is ready; operator credentials: node-panels"
