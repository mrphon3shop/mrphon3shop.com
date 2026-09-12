#!/usr/bin/env bash
# ============================================================================
#  apps/x-ui/setup.sh — first-boot configuration of the 3x-ui panel.
#
#  What is persistent and where:
#    /etc/x-ui/x-ui.db  the whole panel (users, inbounds, settings, node keys)
#                       -> declared as data_paths in manifest/services.json, so
#                          it is age-encrypted into the memory repository and
#                          restored before this script runs.
#    /etc/x-ui/operator-credentials.json  the operator credentials we generated
#                       (same data path, 0600, never printed to a public log).
#
#  The panel is bound to 127.0.0.1 and reached over the tailnet only
#  (tailscale serve --https=8443 --set-path=/xui). Never through Funnel.
# ============================================================================
export LOG_TAG=xui
. "$(dirname "$0")/../../scripts/lib/common.sh"
load_config

XUI_DIR="/usr/local/x-ui"
XUI_BIN="$XUI_DIR/x-ui"
DB_DIR="/etc/x-ui"
CREDS="$DB_DIR/operator-credentials.json"
PORT="${XUI_PORT:-2096}"
USERNAME="${XUI_USERNAME:-mrpadmin}"
[ -x "$XUI_BIN" ] || die "3x-ui is not installed (run scripts/35-programs.sh x-ui)"

sudo mkdir -p "$DB_DIR" /var/log/x-ui
sudo chmod 700 "$DB_DIR"

if sudo test -s "$CREDS"; then
  PASSWORD="$(sudo jq -r '.password' "$CREDS")"
  USERNAME="$(sudo jq -r '.username' "$CREDS")"
  log "operator credentials restored from the previous node (user $USERNAME)"
else
  PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  sudo jq -n --arg u "$USERNAME" --arg p "$PASSWORD" --arg ts "$(iso)" \
       '{username:$u, password:$p, created_at:$ts, note:"3x-ui panel — reachable over the tailnet only"}' \
    | sudo tee "$CREDS" >/dev/null
  sudo chmod 600 "$CREDS"
  log "generated panel credentials and stored them in $CREDS (path only, never printed)"
fi

# apply the settings (idempotent): loopback only, our port, our credentials
sudo "$XUI_BIN" setting -username "$USERNAME" -password "$PASSWORD" -port "$PORT" \
     -listenIP 127.0.0.1 -webBasePath / >/dev/null 2>&1 \
  || warn "could not apply panel settings (first run may need the service to start once)"

sudo chmod 600 "$DB_DIR"/x-ui.db 2>/dev/null || true
log "panel: 127.0.0.1:$PORT  user=$USERNAME  (credentials: sudo cat $CREDS)"
