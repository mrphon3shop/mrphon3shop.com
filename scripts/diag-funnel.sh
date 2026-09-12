#!/usr/bin/env bash
# ============================================================================
#  diag-funnel.sh — measure the real Funnel behaviour on a GitHub runner using
#  a throwaway hostname, so the serving node in the chain is never disturbed.
#    HOLD_SECONDS=120 keeps the public door open after the tests, which lets an
#    external client verify that the exact command handed to the operator works.
# ============================================================================
export LOG_TAG=diag
. "$(dirname "$0")/lib/common.sh"
load_config

if [ -n "${HOLD_SECONDS:-}" ]; then HOLD="$HOLD_SECONDS"; else HOLD="${HOLD:-0}"; fi
[ -z "${HOLD_SECONDS:-}${HOLD:-}" ] && HOLD="${DIAG_HOLD_SECONDS:-0}"
TEST_HOST="${NODE_HOSTNAME}-test"
TS_SOCK=/var/run/tailscale/tailscaled.sock
PORT="${DIAG_PORT:-10000}"

step "tailscale on a throwaway hostname: $TEST_HOST"

if ! have tailscale; then
  retry 2 3 bash -c 'curl -fsSL https://tailscale.com/install.sh | sh' >/dev/null 2>&1 || die "cannot install tailscale"
fi
ts_ready() { sudo tailscale status --json 2>/dev/null | jq -e '.BackendState != null' >/dev/null 2>&1; }
if ! ts_ready; then
  sudo mkdir -p /var/lib/tailscale /var/run/tailscale
  systemctl list-unit-files 2>/dev/null | grep -q tailscaled.service && sudo systemctl start tailscaled >/dev/null 2>&1 || true
  ts_ready || sudo nohup /usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state \
      --socket="$TS_SOCK" >>/var/log/tailscaled.log 2>&1 &
  w=0; until ts_ready; do sleep 0.5; w=$((w+1)); [ $w -gt 60 ] && die "tailscaled did not start"; done
fi

require_secret TS_AUTHKEY
sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$TEST_HOST" --ssh=false \
     --accept-dns=false --timeout=60s >/dev/null 2>&1 || warn "tailscale up returned non-zero"
FQDN="$(sudo tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "" | sub("\\.$";"")')"
[ -n "$FQDN" ] || die "node did not join the tailnet"
echo "fqdn=$FQDN ip=$(sudo tailscale ip -4 2>/dev/null | head -1)"

step "publish the TLS-terminated door on $PORT (Funnel routes by TLS SNI)"
sudo tailscale funnel --bg --yes --tls-terminated-tcp="$PORT" tcp://127.0.0.1:22 2>&1 | tail -3 || true
sleep 2
sudo tailscale funnel status --json 2>/dev/null | jq -c '{TCP:(.TCP|keys), AllowFunnel}' || true

step "wait for the public A record of the funnel name"
for _ in $(seq 1 12); do
  ip="$(getent hosts "$FQDN" 2>/dev/null | awk '{print $1; exit}')"
  [ -n "$ip" ] && { echo "  $FQDN -> $ip"; break; }
  sleep 10
done

step "self-test: the same code path the operator's client uses"
SELFTEST_ATTEMPTS=4 SELFTEST_WAIT_SECONDS=8 bash "$REPO_DIR/scripts/55-funnel-selftest.sh" "$FQDN" "$PORT" || true
jq -c . "$INSTALL_ROOT/state/funnel_selftest.json" 2>/dev/null || true

step "client-side proof (openssl through the relay, raw output)"
timeout 25 openssl s_client -connect "$FQDN:$PORT" -servername "$FQDN" -quiet </dev/null 2>/dev/null | head -c 60 | tr -d '\r' || true
echo
echo "  ^ the line above must start with SSH-2.0 — that is the node's sshd answering"

if [ "${HOLD:-0}" -gt 0 ] 2>/dev/null; then
  step "holding the door open for ${HOLD}s so the operator can connect from outside"
  echo "::notice title=Funnel test door open::ssh -p $PORT root@$FQDN (TLS door, requires a TLS-wrapping client)"
  sleep "$HOLD"
fi

step "cleanup (throwaway node disappears; the live node is untouched)"
sudo tailscale funnel reset >/dev/null 2>&1 || true
sudo tailscale logout >/dev/null 2>&1 || true
echo "done"
