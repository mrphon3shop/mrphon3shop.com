#!/usr/bin/env bash
# tests/check_public.sh <fqdn> <port> <mode>
set -euo pipefail
fqdn="$1"; port="$2"; mode="${3:-tcp}"
# 1) DNS must resolve publicly
ip4="$(getent ahostsv4 "$fqdn" 2>/dev/null | awk '{print $1; exit}')"
getent hosts "$fqdn" >/dev/null || { echo "cannot resolve $fqdn"; exit 1; }
[ -n "$ip4" ] && echo "relay address (v4): $ip4"
# 2) the public relay port must accept a TCP connection
(exec 3<>/dev/tcp/$fqdn/$port) 2>/dev/null || { echo "cannot connect to $fqdn:$port"; exit 1; }
if [ "$mode" = tcp ]; then
  # raw forward: the ssh banner must arrive promptly
  banner="$(timeout 12 bash -c "exec 3<>/dev/tcp/${ip4:-$fqdn}/$port; head -c 40 <&3" 2>/dev/null || true)"
  grep -q '^SSH-2.0' <<<"$banner" || { echo "no ssh banner through $fqdn:$port"; exit 1; }
  echo "ssh banner via public funnel: $(echo "$banner" | tr -d '\r')"
else
  # tls-terminated forward: TLS is terminated by the relay and the plaintext
  # stream is handed to this node's sshd, so the ssh banner must come back
  # *inside* the tunnel. That is the exact trip a client makes.
  banner="$(timeout 20 openssl s_client -4 -connect "$fqdn:$port" -servername "$fqdn" -quiet </dev/null 2>/dev/null | head -c 40 || true)"
  [ -z "$banner" ] && banner="$(timeout 20 openssl s_client -connect "$fqdn:$port" -servername "$fqdn" -quiet </dev/null 2>/dev/null | head -c 40 || true)"
  grep -q '^SSH-2.0' <<<"$banner" || { echo "no ssh banner inside the tunnel on $fqdn:$port (got: $(tr -d '\r' <<<"$banner" | head -c 40))"; exit 1; }
  echo "ssh banner inside the TLS tunnel: $(tr -d '\r' <<<"$banner")"
fi
