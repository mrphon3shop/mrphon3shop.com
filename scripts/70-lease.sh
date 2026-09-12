#!/usr/bin/env bash
# ============================================================================
#  70-lease.sh — single-writer leadership for the chain.
#  The lease lives in the memory repository and is signed; it is what keeps
#  exactly one node serving and lets a standby take over without races.
#    acquire | status | watch | release | handoff <succ_run> | refresh
# ============================================================================
export LOG_TAG=lease
. "$(dirname "$0")/lib/common.sh"
. "$SCRIPT_DIR/lib/memrepo.sh"
load_config

NODE_STATE_DIR="$INSTALL_ROOT/state"; mkdir -p "$NODE_STATE_DIR"
MY_RUN="${GITHUB_RUN_ID:-local}"
LEASE="$MEM_DIR/state/lease.json"
GRACE="${LEASE_GRACE_SECONDS:-180}"

_lease_load() {
  mem_pull >/dev/null 2>&1 || true
  if [ ! -s "$LEASE" ]; then return 1; fi
  if mem_state_verified lease.json; then LEASE_TRUST=ok; else LEASE_TRUST=unverified; fi
  jq -e . "$LEASE" >/dev/null 2>&1
}

_lease_write() { # takes json on stdin, signs, pushes
  local tmp; tmp="$(mktemp)"
  cat >"$tmp"
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    warn "refusing to publish an invalid lease document"; rm -f "$tmp"; return 1
  fi
  mem_write_state lease.json "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  cp "$tmp" "$NODE_STATE_DIR/lease.local.json"
  rm -f "$tmp"
}

_expires_epoch() { jq -r '.expires_at // empty' "$LEASE" 2>/dev/null | { read -r v; [ -n "$v" ] && date -u -d "$v" +%s || echo 0; }; }
_hb_epoch()      { jq -r '.heartbeat_at // empty' "$LEASE" 2>/dev/null | { read -r v; [ -n "$v" ] && date -u -d "$v" +%s || echo 0; }; }

_holder()      { jq -r '.holder.run_id // ""' "$LEASE" 2>/dev/null | head -1; }
_is_mine()     { [ "$(_holder)" = "$MY_RUN" ]; }
_successor_of_mine() { [ "$(jq -r '.next_holder_run // ""' "$LEASE" 2>/dev/null | head -1)" = "$MY_RUN" ]; }

# ---------------------------------------------------------------------------
lease_acquire() {
  local attempt expires hb holder state
  for attempt in 1 2 3 4 5; do
    if ! _lease_load; then
      log "no lease yet — claiming it"
      _lease_emit serving && return 0
      continue
    fi
    holder="$(_holder)"; expires="$(_expires_epoch)"; hb="$(_hb_epoch)"
    state="$(jq -r '.state // "serving"' "$LEASE")"
    log "lease: holder=${holder:0:12} state=$state expires_in=$(( expires - $(now) ))s hb_age=$(( $(now) - hb ))s trust=${LEASE_TRUST:-unknown}"

    if _is_mine; then
      _lease_emit serving && return 0   # refresh our own lease
    elif [ "$state" = handoff ] && _successor_of_mine; then
      log "handoff addressed to this run — taking over"
      _lease_emit serving && return 0
    elif [ "$expires" -lt "$(( $(now) - GRACE ))" ]; then
      log "lease expired ${expires} < $(( $(now) - GRACE )) — taking over stale holder"
      _lease_emit serving && return 0
    elif [ "$hb" -lt "$(( $(now) - 900 ))" ] && [ "$expires" -lt "$(now)" ]; then
      warn "holder heartbeat is stale ($(($(now)-hb))s) and lease expired — taking over"
      _lease_emit serving && return 0
    else
      return 1   # somebody else is serving
    fi
  done
  return 1
}

_lease_emit() { # state
  local st="$1" now prev
  now="$(now)"
  prev="$(jq -r '.epoch // 0' "$LEASE" 2>/dev/null | head -1 || echo 0)"
  [ -z "$prev" ] && prev=0
  jq -n --arg run "$MY_RUN" --arg dev "${NODE_HOSTNAME}.${TAILNET_DNS}" --arg node "$NODE_HOSTNAME" \
        --arg ts "$(iso)" --argjson expires "$(( now + JOB_MAX_MINUTES * 60 + GRACE ))" \
        --argjson prevepoch "$prev" --arg state "$st" --arg url "${RUN_URL:-}" \
     '{holder:{run_id:$run, device:$dev, node:$node, started_at:$ts, url:$url},
       state:$state, epoch:($prevepoch + 1), acquired_at:$ts, expires_at:$expires,
       heartbeat_at:($ts|fromdateiso8601)}' 2>/dev/null \
  | _lease_write
}

lease_refresh() {
  _lease_load || return 1
  _is_mine || { warn "refresh refused: not the holder"; return 1; }
  cat "$LEASE" | jq --arg ts "$(iso)" --argjson exp "$(( $(now) + JOB_MAX_MINUTES * 60 + GRACE ))" \
      '.heartbeat_at = ($ts|fromdateiso8601) | .expires_at = $exp' | _lease_write
}

lease_handoff() { # successor_run_id
  local succ="$1"
  _lease_load || return 1
  _is_mine || { warn "handoff refused: not the holder"; return 1; }
  jq --arg succ "$succ" --arg ts "$(iso)" --argjson exp "$(( $(now) + 300 ))" \
     '.state="handoff" | .next_holder_run=$succ | .handoff_at=$ts | .expires_at=$exp' "$LEASE" | _lease_write
}

lease_release() {
  _lease_load || return 1
  _is_mine || return 0
  jq --arg ts "$(iso)" --argjson now "$(now)" \
     '.state="free" | .expires_at=($now-1) | .released_at=$ts | .holder={run_id:"",device:"",started_at:$ts}' "$LEASE" | _lease_write
}

lease_show() {
  _lease_load || { echo '{"state":"absent"}'; return 0; }
  jq --arg trust "${LEASE_TRUST:-unknown}" '. + {signature_trust:$trust}' "$LEASE"
}

# standby loop: returns 0 as soon as this run owns the lease
cmd_watch() {
  local waited=0 limit="${1:-$HANDOFF_WAIT_SECONDS}"
  log "standby: waiting for the lease (max ${limit}s, poll ${STANDBY_POLL_SECONDS}s)"
  while [ "$waited" -lt "$limit" ]; do
    if lease_acquire; then
      log "standby -> leader after ${waited}s"
      return 0
    fi
    sleep "${STANDBY_POLL_SECONDS:-15}"; waited=$(( waited + ${STANDBY_POLL_SECONDS:-15} ))
    if [ $(( waited % 60 )) -eq 0 ]; then
      jq -n --arg run "$MY_RUN" --arg node "$NODE_HOSTNAME" --arg ts "$(iso)" --argjson waited "$waited" \
         '{run_id:$run,node:$node,standby_seconds:$waited,ready:true,ts:$ts}' >"$NODE_STATE_DIR/standby.json"
      mem_write_state handoff.json "$NODE_STATE_DIR/standby.json" >/dev/null 2>&1 || true
    fi
  done
  warn "standby timed out after ${limit}s without becoming leader"
  lease_acquire
}

case "${1:-status}" in
  acquire)
    if lease_acquire; then echo "leader"; else echo "standby"; fi ;;
  status)  lease_show ;;
  refresh) lease_refresh && echo refreshed ;;
  handoff) lease_handoff "${2:?successor run id required}" && echo handed-off ;;
  release) lease_release && echo released ;;
  watch)   cmd_watch "${2:-}" && echo "leader" ;;
  *) die "usage: $0 acquire|status|watch|refresh|handoff <run>|release" ;;
esac
