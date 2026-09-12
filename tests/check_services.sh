#!/usr/bin/env bash
set -euo pipefail
f=/opt/mrphon3shop/state/services.json
[ -s "$f" ] || { echo "services not applied yet"; exit 1; }
bad="$(jq -r '[.services[]? | select(.state != "healthy")] | length' "$f")"
total="$(jq -r '.services|length' "$f")"
[ "$bad" = "0" ] || { jq -r '.services[]? | select(.state != "healthy") | "unhealthy: \(.name) (\(.state))"' "$f"; exit 1; }
echo "all $total service(s) healthy"
