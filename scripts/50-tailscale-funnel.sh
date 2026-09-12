#!/usr/bin/env bash
# ============================================================================
#  50-tailscale-funnel.sh — bring up the private network + the public SSH door.
#    * tailscaled (systemd if available, direct daemon otherwise)
#    * tailscale up with the ephemeral tagged auth key
#    * Funnel forwarder -> local sshd, with version-tolerant command fallbacks
#    * tailnet-only Serve for the panel/apps (public surface stays minimal)
# ============================================================================
export LOG_TAG=tailscale
. "$(dirname "$0")/lib/common.sh"
. "$SCRIPT_DIR/lib/memrepo.sh"
load_config

START="$(now)"
TS="tailscale"
NODE_STATE_DIR="$INSTALL_ROOT/state"
mkdir -p "$NODE_STATE_DIR"

tsdo() { sudo tailscale "$@"; }

# ---------------------------------------------------------------- install ---
step "tailscale binary"
if ! have tailscale; then
  log "installing tailscale (official installer)"
  retry 2 3 bash -c 'curl -fsSL https://tailscale.com/install.sh | sh' >/tmp/ts_install.log 2>&1 || {
    warn "installer failed: $(tail -2 /tmp/ts_install.log)"; die "tailscale unavailable"
  }
fi
TS_VER="$(tailscale version 2>/dev/null | head -1 || echo unknown)"
log "tailscale version: $TS_VER"

# ---------------------------------------------------------------- daemon ----
step "tailscaled"
if ! sudo tailscale status >/dev/null 2>&1; then
  if systemctl list-unit-files 2>/dev/null | grep -q '^tailscaled.service'; then
    sudo systemctl enable tailscaled >/dev/null 2>&1 || true
    sudo systemctl start tailscaled >/dev/null 2>&1 || true
  fi
  if ! sudo tailscale status >/dev/null 2>&1; then
    log "starting tailscaled directly (no usable systemd unit)"
    sudo mkdir -p /var/lib/tailscale /var/run/tailscale
    sudo nohup /usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state \
         --socket=/var/run/tailscale/tailscaled.sock >/var/log/tailscaled.log 2>&1 &
  fi
  waited=0
  until sudo tailscale status >/dev/null 2>&1; do
    sleep 0.5; waited=$((waited+1)); [ "$waited" -gt 40 ] && die "tailscaled did not come up in 20s"
  done
fi
log "tailscaled reachable"

# ---------------------------------------------------------------- up --------
step "join tailnet (ephemeral, tagged ${TS_TAG}, hostname ${NODE_HOSTNAME})"
BACKEND_STATE="$(tsdo status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')"
CUR_NAME="$(tsdo status --json 2>/dev/null | jq -r '.Self.DNSName // "" | sub("\\.$";"")')"

if [ "$BACKEND_STATE" != "Running" ] || [ -z "$CUR_NAME" ]; then
  require_secret TS_AUTHKEY
  log "auth key: $(mask "$TS_AUTHKEY")"
  tsdo up --authkey="$TS_AUTHKEY" --hostname="$NODE_HOSTNAME" --ssh=false \
          --accept-dns="${TAILSCALE_ACCEPT_DNS:-false}" --accept-routes=false \
          --timeout=60s 2>&1 | sed 's/^/  /' || warn "tailscale up returned non-zero"
  waited=0
  while :; do
    BACKEND_STATE="$(tsdo status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')"
    [ "$BACKEND_STATE" = "Running" ] && break
    sleep 1; waited=$((waited+1))
    [ "$waited" -gt 45 ] && { warn "backend state is $BACKEND_STATE after 45s"; break; }
  done
fi

CUR_NAME="$(tsdo status --json 2>/dev/null | jq -r '.Self.DNSName // "" | sub("\\.$";"")')"
TS_IP="$(tsdo ip -4 2>/dev/null | head -1)"
log "backend=$BACKEND_STATE name=${CUR_NAME:-none} ip=${TS_IP:-none}"

# hostname collision (a stale node still holding the name) -> re-register once
if [ -n "$CUR_NAME" ] && [ "${CUR_NAME%%.*}" != "$NODE_HOSTNAME" ]; then
  warn "node name is '$CUR_NAME' but '$NODE_HOSTNAME' is wanted (stale device holds it) — re-registering once"
  tsdo logout >/dev/null 2>&1 || true
  tsdo up --authkey="$TS_AUTHKEY" --hostname="$NODE_HOSTNAME" --ssh=false \
          --accept-dns="${TAILSCALE_ACCEPT_DNS:-false}" --timeout=60s >/dev/null 2>&1 || true
  sleep 2
  CUR_NAME="$(tsdo status --json 2>/dev/null | jq -r '.Self.DNSName // "" | sub("\\.$";"")')"
  TS_IP="$(tsdo ip -4 2>/dev/null | head -1)"
  log "after re-register: name=${CUR_NAME:-none} ip=${TS_IP:-none}"
fi

FQDN="${CUR_NAME:-${NODE_HOSTNAME}.${TAILNET_DNS}}"
FUNNEL_OK=false
FUNNEL_MODE=""
FUNNEL_PORT=""

# ---------------------------------------------------------------- funnel ----
step "funnel: public SSH door"
funnel_status_has() { tsdo funnel status --json 2>/dev/null | jq -e --arg p "$1" '(.TCP // {}) | to_entries[] | select(.key|tostring|endswith($p))' >/dev/null 2>&1; }

try_funnel() { # try_funnel <mode> <port>
  local mode="$1" port="$2" target="tcp://127.0.0.1:${SSHD_PORT:-22}"
  local -a variants
  case "$mode" in
    tcp) variants=(
            "--tcp=${port} ${target}"
            "--tcp ${port} ${target}"
            "--tcp=${port} ${SSHD_PORT:-22}"
          ) ;;
    tls) variants=(
            "--tls-terminated-tcp=${port} ${target}"
            "--tls-terminated-tcp ${port} ${target}"
            "--tls-terminated-tcp=${port} ${SSHD_PORT:-22}"
          ) ;;
  esac
  local v
  for v in "${variants[@]}"; do
    # shellcheck disable=SC2086
    if tsdo funnel --bg $v --yes >/tmp/funnel.try.log 2>&1; then
      sleep 1
      if funnel_status_has "$port"; then
        log "funnel OK: mode=$mode port=$port (cmd: funnel --bg $v)"
        printf '%s' "$v" >"$NODE_STATE_DIR/funnel_cmd"
        return 0
      fi
    fi
  done
  warn "funnel mode=$mode port=$port failed: $(head -2 /tmp/funnel.try.log | tr '\n' ' ')"
  return 1
}

if try_funnel "$FUNNEL_PRIMARY_MODE" "$FUNNEL_PRIMARY_PORT"; then
  FUNNEL_OK=true; FUNNEL_MODE="$FUNNEL_PRIMARY_MODE"; FUNNEL_PORT="$FUNNEL_PRIMARY_PORT"
elif [ "${FUNNEL_ENABLE_ALT:-auto}" != "never" ] && try_funnel "$FUNNEL_ALT_MODE" "$FUNNEL_ALT_PORT"; then
  FUNNEL_OK=true; FUNNEL_MODE="$FUNNEL_ALT_MODE"; FUNNEL_PORT="$FUNNEL_ALT_PORT"
fi

# ---------------------------------------------------------------- serve -----
step "tailnet-only serve fallback (keeps SSH reachable inside the tailnet)"
if [ "${TAILNET_SSH_FALLBACK:-true}" = "true" ]; then
  tsdo serve --bg --tcp="${SERVE_FALLBACK_PORT:-2222}" "tcp://127.0.0.1:${SSHD_PORT:-22}" >/dev/null 2>&1 || \
  tsdo serve --bg --tcp="${SERVE_FALLBACK_PORT:-2222}" "${SSHD_PORT:-22}" >/dev/null 2>&1 || \
  warn "tailnet serve fallback not configured"
fi

# ---------------------------------------------------------------- report ----
ACTIVE_FUNNEL="$(jq -r '.AllowFunnel // {} | to_entries[]? | select(.value==true) | .key' <(tsdo status --json 2>/dev/null) 2>/dev/null | head -3 | tr '\n' ' ')"
SSH_PUBLIC=""
if [ "$FUNNEL_OK" = true ]; then
  if [ "$FUNNEL_MODE" = tcp ]; then
    SSH_PUBLIC="ssh -p ${FUNNEL_PORT} root@${FQDN}"
  else
    SSH_PUBLIC="ssh (TLS) -p ${FUNNEL_PORT} root@${FQDN}"
  fi
fi

jq -n --arg host "$FQDN" --arg ip "$TS_IP" --arg mode "$FUNNEL_MODE" --argjson port "${FUNNEL_PORT:-0}" \
      --argjson ok "$FUNNEL_OK" --arg ver "$TS_VER" --arg state "$BACKEND_STATE" \
      --arg ssh "$SSH_PUBLIC" --arg ts "$(iso)" --argjson enabled "$(tsdo status --json 2>/dev/null | jq -r '[.AllowFunnel[]?]|any' 2>/dev/null || echo false)" \
      '{hostname:$host, tailnet_ip:$ip, funnel:{enabled:($ok==true), mode:$mode, port:$port, ssh_command:$ssh},
        tailscale_version:$ver, backend_state:$state, attempted_funnel_ports:$enabled, updated_at:$ts}' \
      >"$NODE_STATE_DIR/funnel.json"

jq -r '"  fqdn=\(.hostname)  funnel=\(.funnel.enabled) mode=\(.funnel.mode // "-") port=\(.funnel.port)  ip=\(.tailnet_ip)"' "$NODE_STATE_DIR/funnel.json" >&2
[ -n "$SSH_PUBLIC" ] && log "public SSH: $SSH_PUBLIC"
[ "$FUNNEL_OK" = true ] || warn "Funnel not active — public SSH unavailable this boot (tailnet SSH still works)"

mem_pull >/dev/null 2>&1 || true
mem_write_state funnel.json "$NODE_STATE_DIR/funnel.json" >/dev/null 2>&1 && log "funnel state published to memory repo"
log "tailscale stage finished in $(( $(now) - START ))s"
