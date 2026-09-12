#!/usr/bin/env bash
# ============================================================================
#  guard.sh — cheap pre-flight for scheduled runs.
#  A scheduled run boots a full node; if a healthy node is already serving
#  (fresh heartbeat), the run exits in a few seconds instead of fighting for
#  the lease.  This is the redundancy net, not the primary chain mechanism.
# ============================================================================
export LOG_TAG=guard
. "$(dirname "$0")/lib/common.sh"
load_config

GUARD_MINUTES="${SCHEDULE_GUARD_MINUTES:-25}"
SKIP=0
TMP="$(mktemp -d)"

git clone --depth 1 --quiet "https://github.com/${MEMORY_OWNER}/${MEMORY_REPO}.git" "$TMP/mem" 2>/dev/null || {
  warn "cannot read the memory repository — booting a node instead of skipping"
  echo "SKIP=0" >>"${GITHUB_ENV:-/dev/null}"; exit 0
}

HB="$TMP/mem/state/heartbeat.json"
if [ -s "$HB" ]; then
  age="$(( $(now) - $(jq -r '.epoch // 0' "$HB") ))"
  role="$(jq -r '.role // "?"' "$HB")"
  status="$(jq -r '.status // "?"' "$HB")"
  funnel="$(jq -r '.funnel.enabled // false' "$HB")"
  log "last heartbeat: ${age}s ago, role=${role}, status=${status}, funnel=${funnel}"
  if [ "$age" -lt $(( GUARD_MINUTES * 60 )) ] && [ "$status" = "running" ]; then
    SKIP=1
  fi
else
  log "no heartbeat yet — this run will start the chain"
fi

# a run already in progress (queued or running) is enough
if [ "$SKIP" = 0 ] && [ -n "${WORKFLOW_PAT:-}" ]; then
  active="$(curl -s -m 15 -H "Authorization: Bearer $WORKFLOW_PAT" -H 'Accept: application/vnd.github+json' \
     "https://api.github.com/repos/${MAIN_OWNER}/${MAIN_REPO}/actions/workflows/node.yml/runs?status=in_progress&per_page=5" \
     | jq -r '[.workflow_runs[]? | select(.id != (.id))] | length' 2>/dev/null || echo 0)"
  [ "${active:-0}" -gt 0 ] && { log "another node workflow is already running — skipping"; SKIP=1; }
fi

rm -rf "$TMP"
echo "SKIP=$SKIP" >>"${GITHUB_ENV:-/dev/null}"
if [ "$SKIP" = 1 ]; then
  log "guard: node is healthy (heartbeat < ${GUARD_MINUTES} min) — this scheduled run stops here"
  echo "healthy node already serving; scheduled guard exit" >"${GITHUB_STEP_SUMMARY:-/dev/null}"
else
  log "guard: no healthy node found — continuing to boot"
fi
