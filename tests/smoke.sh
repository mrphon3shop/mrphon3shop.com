#!/usr/bin/env bash
# ============================================================================
#  tests/smoke.sh — verification of the running node.
#  Budget: 150 s hard cap (the whole chain should be up in ~2-3 minutes).
#  Checks run in parallel; failures are reported, never fatal for the node.
# ============================================================================
LOG_TAG=smoke
. "$(dirname "$0")/../scripts/lib/common.sh"
load_config

BUDGET="${SMOKE_BUDGET_SECONDS:-150}"
T0="$(now)"
mkdir -p "$INSTALL_ROOT/state"
OUT="$INSTALL_ROOT/state/smoke.json"
TMP="$(mktemp -d)"
PASS=0; FAIL=0; INFO=0

_check() { # id description command...
  local id="$1" desc="$2"; shift 2
  local log="$TMP/$id.log"
  if timeout 45 "$@" >"$log" 2>&1; then
    echo "PASS  $desc"
    printf '{"id":"%s","desc":"%s","ok":true}\n' "$id" "$desc" >>"$TMP/results"
  else
    echo "FAIL  $desc — $(tail -1 "$log" 2>/dev/null)"
    printf '{"id":"%s","desc":"%s","ok":false,"detail":"%s"}\n' "$id" "$desc" "$(tail -1 "$log" | tr -d '"' | cut -c1-160)" >>"$TMP/results"
  fi
}

step "smoke tests (budget ${BUDGET}s)"
: >"$TMP/results"

# ---- checks that need no waiting ------------------------------------------
_check root-ssh     "sshd is listening and key-only"          tests/check_sshd.sh
_check tailscale    "tailnet node is connected"               tests/check_tailscale.sh
_check funnel-state "funnel config is published"              tests/check_funnel.sh
_check services     "declared services are healthy"           tests/check_services.sh
_check inventory    "package inventory converged"             tests/check_inventory.sh
_check disk         "disk + memory headroom"                  tests/check_resources.sh

# ---- public reachability (the point of the whole setup) --------------------
# Tailscale Funnel routes by TLS SNI, so the only meaningful test is a client
# doing the full trip: DNS -> relay -> TLS -> sshd answering. That is exactly
# what 55-funnel-selftest.sh measures, and it is also re-run by the watchdog.
if [ -s "$INSTALL_ROOT/state/funnel.json" ] && [ "$(jq -r '.funnel.enabled' "$INSTALL_ROOT/state/funnel.json")" = "true" ]; then
  FQDN="$(jq -r '.hostname' "$INSTALL_ROOT/state/funnel.json")"
  FPORT="$(jq -r '.funnel.port' "$INSTALL_ROOT/state/funnel.json")"
  FMODE="$(jq -r '.funnel.mode' "$INSTALL_ROOT/state/funnel.json")"
  _check public-door "a real client reaches sshd through the funnel (${FQDN}:${FPORT} ${FMODE})" \
     bash -c "SELFTEST_ATTEMPTS=3 SELFTEST_WAIT_SECONDS=8 bash '$REPO_DIR/scripts/55-funnel-selftest.sh' '$FQDN' '$FPORT' >/dev/null 2>&1"
  _check public-sshd "ssh banner arrives inside the public tunnel" tests/check_public.sh "$FQDN" "$FPORT" "$FMODE"
else
  echo "WARN  public-door skipped — funnel inactive this boot"
  printf '{"id":"public-door","desc":"public entry","ok":false,"detail":"funnel inactive"}\n' >>"$TMP/results"
fi

# ---- aggregate -------------------------------------------------------------
PASS="$(grep -c '"ok":true' "$TMP/results" || true)"
FAIL="$(grep -c '"ok":false' "$TMP/results" || true)"
SECS=$(( $(now) - T0 ))
jq -s --arg ts "$(iso)" --argjson secs "$SECS" --argjson pass "$PASS" --argjson fail "$FAIL" \
   --arg run "${GITHUB_RUN_ID:-local}" --arg node "$NODE_HOSTNAME" \
   '{at:$ts, node:$node, run_id:$run, seconds:$secs, passed:$pass, failed:$fail, checks:.}' "$TMP/results" >"$OUT"

echo
echo "smoke: ${PASS} passed, ${FAIL} failed, ${SECS}s (budget ${BUDGET}s)"
[ "$SECS" -gt "$BUDGET" ] && warn "smoke tests exceeded the ${BUDGET}s budget"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### smoke tests — ${NODE_HOSTNAME} (run ${GITHUB_RUN_ID:-local})"; echo
    echo "| check | result | detail |"; echo "|---|---|---|"
    jq -rs '.[] | "| \(.desc) | \(if .ok then "✅" else "❌" end) | \(.detail // "") |"' "$TMP/results"
    echo; echo "_${PASS} passed · ${FAIL} failed · ${SECS}s_"; } >>"$GITHUB_STEP_SUMMARY"
fi
rm -rf "$TMP"
[ "$FAIL" -eq 0 ] || warn "smoke tests reported ${FAIL} failing check(s) — node keeps running"
exit 0
