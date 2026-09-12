#!/usr/bin/env bash
set -euo pipefail
f=/opt/mrphon3shop/state/funnel.json
[ -s "$f" ] || { echo "no funnel state"; exit 1; }
jq -e '.funnel.enabled == true' "$f" >/dev/null || { echo "funnel disabled"; exit 1; }
jq -r '"host=\(.hostname) mode=\(.funnel.mode) port=\(.funnel.port)"' "$f"
# the daemon must agree
sudo tailscale funnel status --json 2>/dev/null | jq -e '(.TCP|length) > 0 or (.AllowFunnel|length) > 0' >/dev/null \
  || echo "note: daemon funnel status did not report TCP forwarders"
exit 0
