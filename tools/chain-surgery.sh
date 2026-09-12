#!/usr/bin/env bash
# ============================================================================
#  chain-surgery.sh — operator-side recovery for the runner chain.
#  Runs OUTSIDE the repos (uses the local secret store, never prints a secret).
#    usage: chain-surgery.sh release-lease      # free a lease held by a dead run
#           chain-surgery.sh clear-devices      # remove stale tailnet devices
#           chain-surgery.sh reboot             # release + clear + dispatch a node
# ============================================================================
set -Eeuo pipefail
SECRETS="${SECRETS:-/home/user/.secrets}"
GH=/home/user/bin/gh
export GH_TOKEN="$(cat "$SECRETS/gh_pat")"
MEM=/home/user/repos/mrphon3shop-data
MAIN_REPO=mrphon3shop/mrphon3shop.com
NAME_HOST="${NODE_HOSTNAME:-mrphon3shop-node}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

release_lease() { # write a signed "free" lease so a successor may take over
  cd "$MEM"
  git pull -q --rebase "https://x-access-token:${GH_TOKEN}@github.com/mrphon3shop/mrphon3shop-data.git" main || true
  local now iso
  now="$(date -u +%s)"; iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --argjson exp "$(( now - 5 ))" --argjson hb "$(( now - 5 ))" --arg ts "$iso" \
     '{holder:{run_id:"",device:"",node:"",started_at:$ts},state:"free",epoch:0,acquired_at:$ts,
       expires_at:$exp,heartbeat_at:$hb,released_at:$ts,released_by:"operator-chain-surgery"}' > state/lease.json
  rm -f state/lease.json.sig
  ssh-keygen -Y sign -q -f "$SECRETS/fleet_sign" -n fleet-manifest state/lease.json </dev/null
  [ -s state/lease.json.sig ] || { log "FATAL: lease signature not produced"; return 1; }
  git add -A
  git -c user.name=mrphon3shop -c user.email=mrphon3shop@users.noreply.github.com \
      commit -qm "ops: signed lease release (chain surgery)" || true
  git push -q "https://x-access-token:${GH_TOKEN}@github.com/mrphon3shop/mrphon3shop-data.git" HEAD:main
  log "lease released to the operator (signed, verified by the next node)"
}

clear_devices() { # delete stale tailnet devices that hold the stable name
  local api list
  api="$(cat "$SECRETS/ts_api_token")"
  list="$(curl -sS --max-time 25 -u "$api:" "https://api.tailscale.com/api/v2/tailnet/-/devices")"
  echo "$list" | jq -r --arg h "$NAME_HOST" \
      '.devices[]? | select(.hostname|test("^"+$h)) | "\(.id) \(.name) \(.connectedToControl)"' \
  | while read -r id name conn; do
      log "removing device $id ($name, connected=$conn)"
      curl -sS --max-time 25 -u "$api:" -X DELETE "https://api.tailscale.com/api/v2/device/$id" -o /dev/null -w "  http=%{http_code}\n"
    done
}

dispatch_node() {
  sleep 3
  "$GH" workflow run node.yml --repo "$MAIN_REPO" -f reason=operator-reboot || return 1
  log "node dispatched"
}

case "${1:-reboot}" in
  release-lease) release_lease ;;
  clear-devices) clear_devices ;;
  reboot) release_lease; clear_devices; dispatch_node ;;
  *) echo "usage: $0 {release-lease|clear-devices|reboot}"; exit 1 ;;
esac
