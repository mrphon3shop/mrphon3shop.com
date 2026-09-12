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
TS_STATE="/var/lib/tailscale/tailscaled.state"
TS_SOCK="/var/run/tailscale/tailscaled.sock"

# `tailscale status` exits non-zero when the node is merely logged out, so ask
# the local API for JSON instead — that tells us the daemon is really alive.
tailscaled_ready() { sudo tailscale status --json 2>/dev/null | jq -e '.BackendState != null' >/dev/null 2>&1; }

_start_tailscaled() { # <extra flags...>
  sudo mkdir -p /var/lib/tailscale /var/run/tailscale
  sudo touch /var/log/tailscaled.log
  sudo nohup /usr/sbin/tailscaled --state="$TS_STATE" --socket="$TS_SOCK" "$@" \
       >>/var/log/tailscaled.log 2>&1 &
  local waited=0
  until tailscaled_ready; do
    sleep 0.5; waited=$((waited + 1))
    [ "$waited" -gt 60 ] && return 1          # 30s
  done
  return 0
}

if tailscaled_ready; then
  log "tailscaled already running"
else
  # 1) the packaged service, when the image has a working systemd
  if systemctl list-unit-files 2>/dev/null | grep -q 'tailscaled.service'; then
    sudo systemctl enable tailscaled >/dev/null 2>&1 || true
    if sudo systemctl start tailscaled >/dev/null 2>&1; then
      waited=0; until tailscaled_ready; do sleep 0.5; waited=$((waited+1)); [ "$waited" -gt 30 ] && break; done
    fi
  fi
  # 2) a plain daemon with a tun device
  if ! tailscaled_ready && [ -c /dev/net/tun ]; then
    log "starting tailscaled directly (tun mode)"
    _start_tailscaled --tun=tailscale0 || true
  fi
  # 3) containers / restricted kernels: userspace networking (serve+funnel still work)
  if ! tailscaled_ready; then
    log "tun mode unavailable — falling back to userspace networking"
    _start_tailscaled --tun=userspace-networking --socks5-server=localhost:1055 || true
  fi
  if ! tailscaled_ready; then
    warn "tailscaled diagnostics:"
    sudo tail -12 /var/log/tailscaled.log 2>/dev/null | sed 's/^/    /' || true
    ls -l /dev/net/tun 2>/dev/null | sed 's/^/    /' || echo "    no /dev/net/tun"
    die "tailscaled could not be started"
  fi
fi
log "tailscaled reachable ($(sudo tailscale version 2>/dev/null | head -1))"

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

FUNNEL_OK=false
FUNNEL_MODE=""
FUNNEL_PORT=""


# ------------------------------------------------------------- hostname -----
# The Funnel name must be stable: it is part of the operator's ssh command and
# of the TLS certificate. A runner that was cancelled without logging out leaves
# an ephemeral device behind that keeps the name, so claim it back explicitly.
ts_self_name() { sudo tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "" | sub("\\.$";"")' ; }
ts_self_key()  { sudo tailscale status --json 2>/dev/null | jq -r '.Self.PublicKey // ""' ; }

api_list_devices() {
  [ -n "${TS_API_TOKEN:-}" ] || return 1
  curl -sS --max-time 20 -u "$TS_API_TOKEN:" "https://api.tailscale.com/api/v2/tailnet/-/devices"
}

api_delete_device() { # api_delete_device <id>
  [ -n "${TS_API_TOKEN:-}" ] || return 1
  curl -sS --max-time 20 -u "$TS_API_TOKEN:" -X DELETE \
    "https://api.tailscale.com/api/v2/device/$1" >/dev/null 2>&1 || return 1
}

join_tailnet() {
  sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$NODE_HOSTNAME" --ssh=false \
       --accept-dns=false --timeout=60s >/dev/null 2>&1 || warn "tailscale up returned non-zero"
  sleep 2
}

reclaim_hostname() { # 0 if we now hold $NODE_HOSTNAME
  local wanted="${NODE_HOSTNAME}.${TAILNET_DNS}" me name ids id attempt
  for attempt in 1 2 3; do
    name="$(ts_self_name)"
    [ "$name" = "$wanted" ] && return 0
    warn "node joined as '${name:-?}' but '$wanted' is wanted (attempt $attempt/3)"
    me="$(ts_self_key)"
    ids="$(api_list_devices 2>/dev/null | jq -r --arg want "$wanted" --arg host "$NODE_HOSTNAME" --arg me "$me" \
            '.devices[]? | select((.name==$want) or (.hostname==$host))
             | select(.nodeKey != $me) | select(.connectedToControl != true) | .id' 2>/dev/null || true)"
    if [ -z "$ids" ]; then
      [ -z "${TS_API_TOKEN:-}" ] && warn "no TS_API_TOKEN — cannot clean up the stale device holding the name"
      log "no removable device holds '$wanted' (relying on ephemeral cleanup)"
    else
      for id in $ids; do
        api_delete_device "$id" && log "removed stale tailnet device $id that held the name"
      done
    fi
    sudo tailscale logout >/dev/null 2>&1 || true
    sleep 3
    join_tailnet
  done
  name="$(ts_self_name)"
  [ "$name" = "$wanted" ] && return 0
  warn "still joined as '$name' — serving anyway (the panel/tailnet door keep working; the public name may differ this boot)"
  return 1
}

FQDN="${CUR_NAME:-${NODE_HOSTNAME}.${TAILNET_DNS}}"
reclaim_hostname || true
CUR_NAME="$(ts_self_name)"
FQDN="${CUR_NAME:-${NODE_HOSTNAME}.${TAILNET_DNS}}"

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
    # NOTE: tailscale >= 1.9x requires ALL flags before the single positional
    # target — `funnel --bg --tcp=10000 tcp://host:22 --yes` fails to parse.
    if tsdo funnel --bg --yes $v >/tmp/funnel.try.log 2>&1; then
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

# publish the second door too when asked — clients behind restrictive networks
# often cannot reach 10000 while 8443 goes through
if [ "${FUNNEL_ENABLE_ALT:-auto}" = always ] && [ "$FUNNEL_PORT" != "${FUNNEL_ALT_PORT}" ]; then
  try_funnel "$FUNNEL_ALT_MODE" "$FUNNEL_ALT_PORT" || warn "second door on ${FUNNEL_ALT_PORT} not published"
fi

# The relay routes on the TLS SNI, so "funnel status says on" is not proof that
# a client can get in. Measure it the way a client does, from here.
SELFTEST_OK=false
if [ "$FUNNEL_OK" = true ]; then
  step "public door self-test (DNS -> relay -> TLS -> sshd)"
  if SELFTEST_ATTEMPTS="${SELFTEST_ATTEMPTS:-8}" SELFTEST_WAIT_SECONDS="${SELFTEST_WAIT_SECONDS:-8}" \
       bash "$SCRIPT_DIR/55-funnel-selftest.sh" "$FQDN" "$FUNNEL_PORT"; then
    SELFTEST_OK=true
  else
    warn "the door is configured but a client cannot get in yet — will be retried by the watchdog"
  fi
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
# The public door is always a TLS door: Funnel relays demultiplex by TLS SNI,
# so the client has to wrap its ssh stream in TLS. Both forms below are exactly
# equivalent; the first needs openssl (Git for Windows ships it).
SSH_PUBLIC=""; SSH_PUBLIC_PS=""
if [ "$FUNNEL_OK" = true ]; then
  SSH_PUBLIC="ssh -p ${FUNNEL_PORT} -o \"ProxyCommand=openssl s_client -quiet -connect %h:%p -servername %h\" root@${FQDN}"
  SSH_PUBLIC_PS="ssh -p ${FUNNEL_PORT} -i C:\keys\node.key -o \"ProxyCommand=powershell -NoProfile -ExecutionPolicy Bypass -File C:\keys\tls-tunnel.ps1 %h %p\" root@${FQDN}"
fi
SSH_TAILNET="ssh root@${FQDN} -p ${SERVE_FALLBACK_PORT:-2222}"

jq -n --arg host "$FQDN" --arg ip "$TS_IP" --arg mode "$FUNNEL_MODE" --argjson port "${FUNNEL_PORT:-0}" \
      --argjson ok "$FUNNEL_OK" --arg ver "$TS_VER" --arg state "$BACKEND_STATE" \
      --arg ssh "$SSH_PUBLIC" --arg sshps "$SSH_PUBLIC_PS" --arg sshtn "$SSH_TAILNET" \
      --argjson tested "${SELFTEST_OK:-false}" --argjson srvport "${SERVE_FALLBACK_PORT:-2222}" --arg ts "$(iso)" \
      --argjson enabled "$(tsdo status --json 2>/dev/null | jq -r '[.AllowFunnel[]?]|any' 2>/dev/null || echo false)" \
      '{hostname:$host, tailnet_ip:$ip,
        funnel:{enabled:($ok==true), verified:($tested==true), mode:$mode, port:$port,
                ssh_command:$ssh, ssh_command_powershell:$sshps},
        tailnet:{ssh_command:$sshtn, port:$srvport},
        tailscale_version:$ver, backend_state:$state, attempted_funnel_ports:$enabled, updated_at:$ts}' \
      >"$NODE_STATE_DIR/funnel.json"

jq -r '"  fqdn=\(.hostname)  funnel=\(.funnel.enabled) mode=\(.funnel.mode // "-") port=\(.funnel.port)  ip=\(.tailnet_ip)"' "$NODE_STATE_DIR/funnel.json" >&2
[ -n "$SSH_PUBLIC" ] && log "public SSH : $SSH_PUBLIC"
log "tailnet SSH: $SSH_TAILNET"
if [ "$FUNNEL_OK" != true ]; then
  warn "Funnel not active — public SSH unavailable this boot (tailnet SSH still works)"
  echo "::error title=Funnel inactive::the public SSH door could not be published; see the funnel section above (tailnet fallback is still available)"
else
  echo "::notice title=Public SSH door::${FQDN}:${FUNNEL_PORT} (${FUNNEL_MODE}, verified=${SELFTEST_OK}) — see docs/WINDOWS-SSH.md"
fi

mem_pull >/dev/null 2>&1 || true
mem_write_state funnel.json "$NODE_STATE_DIR/funnel.json" >/dev/null 2>&1 && log "funnel state published to memory repo"
log "tailscale stage finished in $(( $(now) - START ))s"
