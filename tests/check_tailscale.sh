#!/usr/bin/env bash
set -euo pipefail
command -v tailscale >/dev/null || { echo "tailscale not installed"; exit 1; }
st="$(sudo tailscale status --json 2>/dev/null)" || { echo "tailscale status failed (daemon down)"; exit 1; }
state="$(jq -r '.BackendState' <<<"$st")"
[ "$state" = "Running" ] || { echo "backend state=$state"; exit 1; }
jq -r '.Self.DNSName' <<<"$st" | sed 's/^/name: /'
ip="$(jq -r '.Self.TailscaleIPs[0]' <<<"$st")"; echo "ip: $ip"
