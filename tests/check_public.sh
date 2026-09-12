#!/usr/bin/env bash
# tests/check_public.sh <fqdn> <port> <mode>
set -euo pipefail
fqdn="$1"; port="$2"; mode="${3:-tcp}"
# 1) DNS must resolve publicly
getent hosts "$fqdn" >/dev/null || { echo "cannot resolve $fqdn"; exit 1; }
# 2) the public relay port must accept a TCP connection
(exec 3<>/dev/tcp/$fqdn/$port) 2>/dev/null || { echo "cannot connect to $fqdn:$port"; exit 1; }
if [ "$mode" = tcp ]; then
  # raw forward: the ssh banner must arrive promptly
  banner="$(timeout 12 bash -c "exec 3<>/dev/tcp/$fqdn/$port; head -c 40 <&3" 2>/dev/null || true)"
  grep -q '^SSH-2.0' <<<"$banner" || { echo "no ssh banner through $fqdn:$port"; exit 1; }
  echo "ssh banner via public funnel: $(echo "$banner" | tr -d '\r')"
else
  # tls-terminated forward: TLS handshake must succeed with a ts.net certificate
  out="$(timeout 15 openssl s_client -connect "$fqdn:$port" -servername "$fqdn" </dev/null 2>/dev/null | head -20 || true)"
  grep -qi 'BEGIN CERTIFICATE' <<<"$out" || { echo "TLS handshake failed on $fqdn:$port"; exit 1; }
  echo "TLS handshake ok on $fqdn:$port (tls-terminated forward)"
fi
