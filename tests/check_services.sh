#!/usr/bin/env bash
# Every service that is ENABLED must be healthy. Disabled entries (enabled:false
# in manifest/services.json) are expected to be stopped and are not failures.
set -euo pipefail
f=/opt/mrphon3shop/state/services.json
[ -s "$f" ] || { echo "services not applied yet"; exit 1; }
bad="$(jq -r '[.services[]? | select(.state != "healthy" and .state != "disabled")] | length' "$f")"
total="$(jq -r '[.services[]? | select(.state != "disabled")] | length' "$f")"
if [ "$bad" != "0" ]; then
  jq -r '.services[]? | select(.state != "healthy" and .state != "disabled") | "unhealthy: \(.name) (\(.state))"' "$f"
  exit 1
fi
echo "all $total enabled service(s) healthy"
