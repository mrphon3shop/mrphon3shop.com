#!/usr/bin/env bash
set -euo pipefail
port="${SSHD_PORT:-22}"
# listening?
(exec 3<>/dev/tcp/127.0.0.1/$port) || { echo "sshd not listening on $port"; exit 1; }
exec 3>&- 2>/dev/null || true
# effective config must be key-only
eff="$(sudo sshd -T 2>/dev/null || sshd -T 2>/dev/null || true)"
[ -n "$eff" ] || { echo "cannot dump sshd config"; exit 1; }
grep -qi '^passwordauthentication no' <<<"$eff" || { echo "password auth not disabled"; exit 1; }
grep -qiE '^permitrootlogin (prohibit-password|without-password)' <<<"$eff" || { echo "root login policy unexpected"; exit 1; }
grep -qi '^pubkeyauthentication yes' <<<"$eff" || { echo "pubkey auth disabled"; exit 1; }
[ -s /root/.ssh/authorized_keys ] || { echo "no authorized keys"; exit 1; }
cnt="$(grep -c 'ssh-' /root/.ssh/authorized_keys || true)"
[ "$cnt" -ge 1 ] || { echo "no usable key"; exit 1; }
echo "sshd ok on $port, key-only, $cnt key(s)"
