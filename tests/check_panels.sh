#!/usr/bin/env bash
# The two operator panels (3x-ui, Marzban) must stay declared, persisted and
# reachable on the TAILNET ONLY — never on the public Funnel door.
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/mrphon3shop/work/repo}"
M="$(jq -c . "$REPO_DIR/manifest/services.json")"
fail=0
say() { printf '%s\n' "$*"; }
need() { if [ "$2" = "$3" ]; then say "ok   $1"; else say "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }

for n in x-ui marzban; do
  jq -e --arg n "$n" '.services[] | select(.name==$n)' <<<"$M" >/dev/null \
    || { say "FAIL $n is missing from the catalogue"; fail=1; continue; }
  need "$n enabled=true"   "$(jq -r --arg n "$n" '.services[]|select(.name==$n)|.enabled' <<<"$M")" "true"
  need "$n persist=true"   "$(jq -r --arg n "$n" '.services[]|select(.name==$n)|.persist' <<<"$M")" "true"
  need "$n public=false"   "$(jq -r --arg n "$n" '.services[]|select(.name==$n)|.public // false' <<<"$M")" "false"
  need "$n has data_paths" "$(jq -r --arg n "$n" '.services[]|select(.name==$n)|(.data_paths|length) > 0' <<<"$M")" "true"
  need "$n has a tailnet TCP door" "$(jq -r --arg n "$n" '.services[]|select(.name==$n)|.tailnet_tcp.port // 0' <<<"$M")" \
       "$(jq -r --arg n "$n" '.services[]|select(.name==$n)|.port' <<<"$M")"
  need "$n health path" "$(jq -r --arg n "$n" '.services[]|select(.name==$n)|.health.type' <<<"$M")" "http"
done

# the panels must NOT be exposed through Funnel (public door)
if grep -qE 'funnel .*--https=443 .*127\.0\.0\.1:(2087|8000)' "$REPO_DIR/scripts/40-apply-services.sh" 2>/dev/null; then
  say "FAIL a panel is wired to the public Funnel door"; fail=1
else
  say "ok   panels are not wired to the public Funnel door"
fi

# the tailnet TCP door code path must exist and use tcp://127.0.0.1
if grep -q 'serve --bg --tcp=' "$REPO_DIR/scripts/40-apply-services.sh"; then say "ok   tailnet TCP door code present"; else say "FAIL tailnet TCP door code missing"; fail=1; fi

# and the doors must be re-asserted by the stage that actually brings Tailscale up
if grep -q 'apply_app_doors' "$REPO_DIR/scripts/50-tailscale-funnel.sh"; then
  say "ok   doors are re-asserted once Tailscale is up"
else
  say "FAIL the funnel stage does not re-assert the doors (panels would stay loopback-only)"
  fail=1
fi

[ "$fail" = 0 ] && say "panels: catalogue, persistence and tailnet-only exposure verified"
exit "$fail"
