#!/usr/bin/env bash
# ============================================================================
#  60-heartbeat.sh — cheap liveness beacon for the chain.
#    start | beat | stop <reason>
#  Public, small, signed.  The watchdog in the memory repository and the
#  keepalive cron of the node workflow both read it.
# ============================================================================
export LOG_TAG=heartbeat
. "$(dirname "$0")/lib/common.sh"
. "$SCRIPT_DIR/lib/memrepo.sh"
load_config

NODE_STATE_DIR="$INSTALL_ROOT/state"; mkdir -p "$NODE_STATE_DIR"
HB_FILE="$NODE_STATE_DIR/heartbeat.json"
MY_RUN="${GITHUB_RUN_ID:-local}"
STATUS_FILE="$NODE_STATE_DIR/status"

_write() {
  local status="$1" note="${2:-}"
  local role; role="$(cat "$NODE_STATE_DIR/role" 2>/dev/null || echo unknown)"
  local funnel; funnel="$(jq -c '{enabled:.funnel.enabled,mode:.funnel.mode,port:.funnel.port,hostname:.hostname}' "$NODE_STATE_DIR/funnel.json" 2>/dev/null || echo '{}')"
  local svc; svc="$(jq -c '{total:(.services|length),healthy:([.services[]|select(.state=="healthy")]|length)}' "$NODE_STATE_DIR/services.json" 2>/dev/null || echo '{}')"
  local inv; inv="$(jq -r '.count // 0' "$NODE_STATE_DIR/inventory.json" 2>/dev/null || echo 0)"

  jq -n --arg ts "$(iso)" --argjson now "$(now)" --arg run "$MY_RUN" --arg node "$NODE_HOSTNAME" \
        --arg role "$role" --arg status "$status" --arg note "$note" --arg url "${RUN_URL:-}" \
        --argjson deadline "$(deadline_epoch)" --argjson started "$(cat "$NODE_STATE_DIR/started_epoch" 2>/dev/null || echo "$(now)")" \
        --argjson funnel "$funnel" --argjson services "$svc" --argjson apps "$inv" \
        --arg sha "${GITHUB_SHA:-local}" \
     '{run_id:$run, node:$node, role:$role, status:$status, note:$note, updated_at:$ts,
       epoch:$now, deadline_epoch:$deadline, uptime_seconds:($now-$started), run_url:$url,
       commit:$sha, funnel:$funnel, services:$services, apps_installed:$apps, generation:1}' >"$HB_FILE"
  cp "$HB_FILE" "$MEM_DIR/../heartbeat.local.json" 2>/dev/null || true
  mem_write_state heartbeat.json "$HB_FILE" >/dev/null 2>&1 || warn "heartbeat push failed (will retry next beat)"
  # append-only machine log (pruned)
  mem_append_jsonl nodes.jsonl "$(jq -c . "$HB_FILE")" 400 2>/dev/null || true
  log "beat: status=$status role=$role deadline_in=$(( $(deadline_epoch) - $(now) ))s"
}

case "${1:-beat}" in
  start)
    echo "$(now)" >"$NODE_STATE_DIR/started_epoch"
    echo "${2:-leader}" >"$NODE_STATE_DIR/role"
    _write running "node up" ;;
  beat)  _write "$(cat "$STATUS_FILE" 2>/dev/null || echo running)" "${2:-}" ;;
  note)  echo "$2" >"$STATUS_FILE" ;;
  stop)  _write stopped "${2:-shutdown}" ;;
  *) die "usage: $0 start|beat|note|stop" ;;
esac
