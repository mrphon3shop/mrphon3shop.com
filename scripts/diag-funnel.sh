#!/usr/bin/env bash
# ============================================================================
#  diag-funnel.sh — answer one question on a real GitHub runner:
#  which Funnel mode actually publishes a public door for SSH?
#  It uses a throwaway hostname ("<node>-test") and logs out afterwards, so it
#  never disturbs the serving node in the chain.
# ============================================================================
export LOG_TAG=diag
. "$(dirname "$0")/lib/common.sh"
load_config

TEST_HOST="${NODE_HOSTNAME}-test"
TS_SOCK=/var/run/tailscale/tailscaled.sock
step "tailscale on a throwaway hostname: $TEST_HOST"

if ! have tailscale; then
  retry 2 3 bash -c 'curl -fsSL https://tailscale.com/install.sh | sh' >/dev/null 2>&1 || die "cannot install tailscale"
fi
ts_ready() { sudo tailscale status --json 2>/dev/null | jq -e '.BackendState != null' >/dev/null 2>&1; }
if ! ts_ready; then
  sudo mkdir -p /var/lib/tailscale /var/run/tailscale
  if systemctl list-unit-files 2>/dev/null | grep -q tailscaled.service; then
    sudo systemctl start tailscaled >/dev/null 2>&1 || true
  fi
  if ! ts_ready; then
    sudo nohup /usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket="$TS_SOCK" \
      >>/var/log/tailscaled.log 2>&1 &
  fi
  w=0; until ts_ready; do sleep 0.5; w=$((w+1)); [ $w -gt 60 ] && die "tailscaled did not start"; done
fi

require_secret TS_AUTHKEY
sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$TEST_HOST" --ssh=false \
     --accept-dns=false --timeout=60s >/dev/null 2>&1 || warn "tailscale up returned non-zero"
sleep 2
FQDN="$(sudo tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "" | sub("\\.$";"")')"
IP="$(sudo tailscale ip -4 2>/dev/null | head -1)"
echo "fqdn=$FQDN ip=$IP"
[ -n "$FQDN" ] || die "node did not join the tailnet"

step "DNS before any certificate/funnel"
getent hosts "$FQDN" >/dev/null && echo "  resolves: $(getent hosts "$FQDN")" || echo "  no public A record yet (expected at this point)"

step "provision an HTTPS certificate for the node (this is what publishes the name)"
sudo tailscale cert --cert-file=/tmp/diag.crt --key-file=/tmp/diag.key "$FQDN" 2>&1 | tail -3 || warn "tailscale cert failed"
ls -l /tmp/diag.crt 2>/dev/null | sed 's/^/  /' || true
for _ in 1 2 3 4 5 6; do
  if getent hosts "$FQDN" >/dev/null 2>&1; then echo "  public A record: $(getent hosts "$FQDN")"; break; fi
  sleep 10
done

step "raw TCP funnel on 10000 (plain ssh, best UX)"
sudo tailscale funnel --bg --yes --tcp=10000 tcp://127.0.0.1:22 2>&1 | tail -4 || true
sleep 3
sudo tailscale funnel status --json 2>/dev/null | jq -c '{TCP:(.TCP|keys), AllowFunnel}' || true

step "TLS-terminated funnel on 8443"
sudo tailscale funnel --bg --yes --tls-terminated-tcp=8443 tcp://127.0.0.1:22 2>&1 | tail -4 || true
sleep 3
sudo tailscale funnel status --json 2>/dev/null | jq -c '{TCP:(.TCP|keys), AllowFunnel}' || true
echo "--- human readable ---"
sudo tailscale funnel status 2>&1 | head -18

step "can the public internet reach it? (measured from this runner, over the real path)"
for p in 10000 8443; do
  if timeout 10 bash -c "exec 3<>/dev/tcp/$FQDN/$p" 2>/dev/null; then echo "  port $p: relay accepted the connection"; else echo "  port $p: no connection"; fi
done
banner="$(timeout 12 bash -c "exec 3<>/dev/tcp/$FQDN/10000; head -c 40 <&3" 2>/dev/null | tr -d '\r' || true)"
echo "  raw :10000 banner: ${banner:-<none>}"
tlsout="$(timeout 15 openssl s_client -quiet -connect "$FQDN:8443" -servername "$FQDN" </dev/null 2>/dev/null | head -1 || true)"
echo "  tls :8443 first line: ${tlsout:-<none>}"

step "cleanup"
sudo tailscale funnel reset >/dev/null 2>&1 || true
sudo tailscale logout >/dev/null 2>&1 || true
echo "done"
