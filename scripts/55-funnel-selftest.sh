#!/usr/bin/env bash
# ============================================================================
#  55-funnel-selftest.sh — prove the *public* door works, from the node itself.
#
#  Why this exists: Tailscale Funnel routes by TLS SNI on a shared relay, so a
#  plain "nc host 10000" proves nothing. The only honest test is the one the
#  user's client performs: DNS -> relay -> TLS handshake -> the node's sshd
#  answering inside the tunnel. If sshd answers at all (even with "Permission
#  denied", since we deliberately present no key) the door is open.
#
#  usage: 55-funnel-selftest.sh [fqdn] [port]
#  writes: $INSTALL_ROOT/state/funnel_selftest.json   (exit 0 = door works)
# ============================================================================
export LOG_TAG=funnel-selftest
. "$(dirname "$0")/lib/common.sh"
load_config

STATE_DIR="${INSTALL_ROOT}/state"
FUNNEL_STATE="$STATE_DIR/funnel.json"
FQDN="${1:-}"
PORT="${2:-}"

if [ -z "$FQDN" ] || [ -z "$PORT" ]; then
  FQDN="${FQDN:-$(jq -r '.hostname // ""' "$FUNNEL_STATE" 2>/dev/null)}"
  PORT="${PORT:-$(jq -r '.funnel.port // 0' "$FUNNEL_STATE" 2>/dev/null)}"
fi
FQDN="${FQDN:-${NODE_HOSTNAME}.${TAILNET_DNS}}"
PORT="${PORT:-${FUNNEL_PRIMARY_PORT:-10000}}"

have openssl || die "openssl is required for the funnel self-test"

PROXY="openssl s_client -quiet -connect %h:%p -servername %h"
attempts="${SELFTEST_ATTEMPTS:-6}"
per_attempt="${SELFTEST_WAIT_SECONDS:-5}"

dns_ip=""; banner=""; verdict="no answer"; ok=false; tries=0
for tries in $(seq 1 "$attempts"); do
  dns_ip="$(getent hosts "$FQDN" 2>/dev/null | awk '{print $1; exit}')"
  if [ -z "$dns_ip" ]; then
    verdict="public DNS has no record for $FQDN yet"
    sleep "$per_attempt"; continue
  fi
  # exactly what the user's ssh client does through the pubic door
  out="$(timeout 30 ssh -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none \
            -o StrictHostKeyChecking=no -o "UserKnownHostsFile=$STATE_DIR/../work/selftest_known_hosts" \
            -o "ProxyCommand=$PROXY" -o ConnectTimeout=20 -p "$PORT" "root@$FQDN" true 2>&1)" || true
  if grep -q "Permission denied" <<<"$out"; then
    ok=true; verdict="sshd answered through the public door (key-only, as designed)"; break
  fi
  if grep -qiE "connection refused|connection closed|timed out|timeout|broken pipe|no route|reset by peer|kex_exchange_identification|Connection reset" <<<"$out"; then
    verdict="$(tr '\n' ' ' <<<"$out" | cut -c1-160)"
    sleep "$per_attempt"; continue
  fi
  verdict="$(tr '\n' ' ' <<<"$out" | cut -c1-160)"
  sleep "$per_attempt"
done

# the host key the user will see, so it can be verified out of band
hostkey="$(ssh-keygen -lf "$INSTALL_ROOT/work/selftest_known_hosts" 2>/dev/null | awk '{print $2, $4}' | head -1 || true)"

jq -n --arg fqdn "$FQDN" --argjson port "${PORT:-0}" --arg dns "$dns_ip" \
      --argjson ok "$ok" --arg verdict "$verdict" --arg hostkey "$hostkey" \
      --argjson tries "$tries" --arg ts "$(iso)" \
      '{fqdn:$fqdn, port:$port, dns_ip:$dns, ok:$ok, verdict:$verdict,
        host_key_fingerprint:$hostkey, attempts:$tries, checked_at:$ts}' \
  >"$STATE_DIR/funnel_selftest.json" 2>/dev/null || true

if [ "$ok" = true ]; then
  log "public door OK: $FQDN:$PORT (relay ip $dns_ip) — $verdict"
  [ -n "$hostkey" ] && log "node host key fingerprint: $hostkey"
  exit 0
fi
warn "public door NOT reachable: $FQDN:$PORT — $verdict"
exit 1
