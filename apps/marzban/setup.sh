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
if [ -s "$PW_FILE" ]; then
  admin_pw="$(sudo cat "$PW_FILE")"
  log "reusing the existing operator password"
elif [ -n "${MARZBAN_ADMIN_PASSWORD:-}" ]; then
  admin_pw="$MARZBAN_ADMIN_PASSWORD"
  printf '%s' "$admin_pw" | sudo tee "$PW_FILE" >/dev/null
  log "adopted MARZBAN_ADMIN_PASSWORD from the environment"
else
  # plain `tr </dev/urandom | head` dies of SIGPIPE under `set -o pipefail`
  admin_pw="$(openssl rand -hex 16)"
  printf '%s' "$admin_pw" | sudo tee "$PW_FILE" >/dev/null
  log "generated a new operator password (stored 0600, printed by node-marzban-creds)"
fi
sudo chmod 600 "$PW_FILE"

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
sudo docker compose -f "$DIR/docker-compose.yml" pull --quiet >/dev/null 2>&1 || warn "image pull failed (will retry at start)"
sudo docker compose -f "$DIR/docker-compose.yml" up -d >/dev/null 2>&1 || die "docker compose up failed"

step "waiting for the dashboard"
if wait_http "http://127.0.0.1:8000/dashboard/" 90 200; then
  log "marzban dashboard is answering on 127.0.0.1:8000"
else
  warn "dashboard did not answer within 90s — inspect: docker compose -f $DIR/docker-compose.yml logs --tail=40"
fi
log "marzban is ready; operator credentials: node-marzban-creds"
