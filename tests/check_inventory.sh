#!/usr/bin/env bash
set -euo pipefail
f=/opt/mrphon3shop/state/inventory.json
[ -s "$f" ] || { echo "no inventory"; exit 1; }
missing="$(jq -r '[.packages[]? | select(.status == "MISSING" or .status == "FAILED")] | length' "$f")"
[ "$missing" = "0" ] || { jq -r '.packages[]? | select(.status=="MISSING" or .status=="FAILED") | "missing: \(.name)"' "$f" | head -5; exit 1; }
echo "$(jq -r '.count' "$f") package(s) recorded, 0 missing"
