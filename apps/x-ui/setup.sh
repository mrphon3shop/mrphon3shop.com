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
PORT="${XUI_PORT:-2087}"   # 2096 is 3x-ui's default subscription port
USERNAME="${XUI_USERNAME:-mrpadmin}"
[ -x "$XUI_BIN" ] || die "3x-ui is not installed (run scripts/35-programs.sh x-ui)"

sudo mkdir -p "$DB_DIR" /var/log/x-ui
sudo chmod 700 "$DB_DIR"

if [ -n "${OPERATOR_PASSWORD:-}" ]; then
  # one password for the whole node: the operator already knows it (the same one
  # used for ssh), so nothing new has to be communicated or written down.
  PASSWORD="$OPERATOR_PASSWORD"
  sudo jq -n --arg u "$USERNAME" --arg p "$PASSWORD" --arg ts "$(iso)" \
       '{username:$u, password:$p, created_at:$ts, note:"3x-ui panel — same password as ssh on this node; reachable over the tailnet only"}' \
    | sudo tee "$CREDS" >/dev/null
  sudo chmod 600 "$CREDS"
  log "panel credentials set to the operator password (user $USERNAME)"
elif sudo test -s "$CREDS"; then
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

step "panel runtime (working directory + xray core)"
# 3x-ui resolves its own bin/ directory relative to the process WORKING
# DIRECTORY. Started from anywhere else it cannot write bin/config.json and
# every xray (re)start fails with:
#   Restart xray failed: Failed to write configuration file:
#   open bin/.config-*.tmp: no such file or directory
# — the "xray failed" state the panel then shows. The service unit carries the
# right directory, so a panel running from elsewhere is put back under it.
need_restart=0
for p in $(pgrep -x x-ui 2>/dev/null || true); do
  cwd="$(readlink "/proc/$p/cwd" 2>/dev/null || echo "?")"
  if [ "$cwd" != "$XUI_DIR" ]; then
    warn "the panel (pid $p) runs with working directory $cwd instead of $XUI_DIR"
    need_restart=1
  fi
done
if [ "$need_restart" = 1 ]; then
  sudo systemctl restart mrphon3shop-x-ui.service >/dev/null 2>&1 \
    || sudo systemctl start mrphon3shop-x-ui.service >/dev/null 2>&1 \
    || warn "could not restart the panel service — is it registered?"
  sleep 3
  for p in $(pgrep -x x-ui 2>/dev/null || true); do
    log "panel now runs with working directory $(readlink "/proc/$p/cwd" 2>/dev/null)"
  done
fi
if pgrep -f "xray-linux-amd64" >/dev/null 2>&1; then
  log "xray core: running"
else
  log "xray core: not started yet (the panel starts it a moment after boot)"
fi
log "panel: 127.0.0.1:$PORT  user=$USERNAME  (credentials: sudo cat $CREDS)"
