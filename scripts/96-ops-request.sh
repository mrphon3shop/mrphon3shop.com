#!/usr/bin/env bash
# ============================================================================
#  96-ops-request.sh <handoff|clear|sync> — the operator channel.
#  Writes state/ops.json into the memory repository; every serving node polls it
#  once a minute. `handoff` is the reboot button: the node immediately dispatches
#  a successor and steps aside, and the successor restores the same state.
#  Nothing secret is written here (coordination data only, like the lease).
# ============================================================================
export LOG_TAG=ops
. "$(dirname "$0")/lib/common.sh"
. "$SCRIPT_DIR/lib/memrepo.sh"
load_config

WHAT="${1:-handoff}"
. "$RUN_DIR/node.json" 2>/dev/null || true

case "$WHAT" in
  handoff) HANDOFF=true ;;
  clear)   HANDOFF=false ;;
  sync)    HANDOFF=false ;;
  *)       die "unknown request '$WHAT' (handoff|clear|sync)" ;;
esac

mem_pull >/dev/null 2>&1 || true
TMP="$(mktemp)"
jq -n --argjson h "$HANDOFF" --arg ts "$(iso)" --arg who "${GITHUB_ACTOR:-operator}" \
      --arg mode "$([[ "$WHAT" = sync ]] && echo sync || echo "")" \
      '{handoff:$h, requested_at:$ts, requested_by:$who, also_sync:($mode=="sync")}' >"$TMP"
mem_write_state ops.json "$TMP" >/dev/null 2>&1 || { rm -f "$TMP"; die "could not publish ops.json"; }
rm -f "$TMP"
log "published ops request: $WHAT (the serving node acts within ~60s)"
