#!/usr/bin/env bash
# ============================================================================
#  90-finalize.sh — graceful end of a node: final snapshot, hand the public
#  name to the successor, leave the chain in a clean state.
#    [--reason <text>]
# ============================================================================
export LOG_TAG=finalize
. "$(dirname "$0")/lib/common.sh"
. "$SCRIPT_DIR/lib/memrepo.sh"
load_config

REASON="planned-handover"
[ "${1:-}" = "--reason" ] && REASON="${2:-planned-handover}"
START="$(now)"
NODE_STATE_DIR="$INSTALL_ROOT/state"

step "stop watchdog"
if [ -f "$RUN_DIR/watchdog.pid" ]; then
  kill "$(cat "$RUN_DIR/watchdog.pid")" >/dev/null 2>&1 || true
  rm -f "$RUN_DIR/watchdog.pid"
fi

step "final state snapshot"
"$SCRIPT_DIR/80-state-sync.sh" --final || warn "final snapshot incomplete"

step "publish shutdown notice"
"$SCRIPT_DIR/60-heartbeat.sh" stop "$REASON" || true

step "leave the tailnet (frees ${NODE_HOSTNAME}.${TAILNET_DNS} for the successor)"
if sudo tailscale status >/dev/null 2>&1; then
  sudo tailscale funnel --bg --tcp="${FUNNEL_PRIMARY_PORT}" off >/dev/null 2>&1 || true
  sudo tailscale logout >/dev/null 2>&1 || warn "tailscale logout failed (ephemeral node will expire on its own)"
  log "logged out of the tailnet"
else
  log "tailscale not running — nothing to release"
fi

step "lease"
ROLE="$(cat "$NODE_STATE_DIR/role" 2>/dev/null || echo unknown)"
if [ "$ROLE" = leader ]; then
  lease_json="$("$SCRIPT_DIR/70-lease.sh" status 2>/dev/null || echo '{}')"
  st="$(jq -r '.state // "unknown"' <<<"$lease_json")"
  holder="$(jq -r '.holder.run_id // ""' <<<"$lease_json")"
  nxt="$(jq -r '.next_holder_run // ""' <<<"$lease_json")"
  myrun="${GITHUB_RUN_ID:-local}"
  if [ "$st" = handoff ] && [ -n "$nxt" ] && [ "$nxt" != "$myrun" ]; then
    log "lease already handed to run $nxt — leaving it untouched"
  elif [ "$holder" = "$myrun" ]; then
    "$SCRIPT_DIR/70-lease.sh" release >/dev/null 2>&1 && log "lease released (no successor was waiting)"
  else
    log "lease is held by '${holder:-nobody}' — nothing to release"
  fi
fi

jq -n --arg ts "$(iso)" --arg reason "$REASON" --argjson uptime "$(( $(now) - $(cat "$NODE_STATE_DIR/started_epoch" 2>/dev/null || echo "$(now)") ))" \
      --argjson deadline "$(deadline_epoch)" --argjson over "$( [ "$(now)" -gt "$(deadline_epoch)" ] && echo true || echo false )" \
   '{stopped_at:$ts, reason:$reason, uptime_seconds:$uptime, deadline_epoch:$deadline, past_deadline:($over==true)}' \
   >"$NODE_STATE_DIR/finalize.json"
cat "$NODE_STATE_DIR/finalize.json"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### node ${NODE_HOSTNAME} — ${REASON}"
    echo ""
    echo "| metric | value |"
    echo "|---|---|"
    jq -r '"| run | \(.run_id // "?") |", "| uptime | \(.uptime_seconds)s |", "| funnel | \(.funnel.enabled) \(.funnel.mode // "") :\(.funnel.port // 0) |", "| services healthy | \(.services.healthy // 0)/\(.services.total // 0) |", "| apps installed | \(.apps_installed // 0) |"' "$NODE_STATE_DIR/heartbeat.json" 2>/dev/null || true
    echo ""
    echo "finalize: \`$(jq -c . "$NODE_STATE_DIR/finalize.json")\`"
  } >>"$GITHUB_STEP_SUMMARY"
fi
log "finalize complete in $(( $(now) - START ))s"
