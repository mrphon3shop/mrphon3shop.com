#!/usr/bin/env bash
set -euo pipefail
port="${SSHD_PORT:-22}"
NODE_USERS="${NODE_USERS:-mrphon user}"
# listening?
(exec 3<>/dev/tcp/127.0.0.1/$port) || { echo "sshd not listening on $port"; exit 1; }
exec 3>&- 2>/dev/null || true
# effective config must be key-only
dump() { # sshd -T needs /run/sshd, which a not-yet-started sshd has not created
  local out spec="${1:-}"
  out="$(sudo sshd -T ${spec:+-C "$spec"} 2>/dev/null || true)"
  if [ -z "$out" ]; then
    sudo mkdir -p /run/sshd 2>/dev/null && sudo chmod 0755 /run/sshd 2>/dev/null
    out="$(sudo sshd -T ${spec:+-C "$spec"} 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}
eff="$(dump)"
[ -n "$eff" ] || { echo "cannot dump sshd config"; exit 1; }
grep -qi '^passwordauthentication no' <<<"$eff" || { echo "password auth not disabled"; exit 1; }
grep -qiE '^permitrootlogin (prohibit-password|without-password)' <<<"$eff" || { echo "root login policy unexpected"; exit 1; }
grep -qi '^pubkeyauthentication yes' <<<"$eff" || { echo "pubkey auth disabled"; exit 1; }
[ -s /root/.ssh/authorized_keys ] || { echo "no authorized keys"; exit 1; }
cnt="$(grep -c 'ssh-' /root/.ssh/authorized_keys || true)"
[ "$cnt" -ge 1 ] || { echo "no usable key"; exit 1; }
echo "sshd ok on $port, key-only, $cnt key(s)"
# --- tailnet-scoped password policy (see docs/SECURITY.md) -------------------
# The operator logs in with a password, but only from inside the tailnet: the
# public Funnel door arrives on loopback and must stay key-only.
tailnet_ok="$(dump addr=100.66.254.29,user=root,host=n,laddr=100.66.254.29,lport=22 | awk '/^passwordauthentication/{print $2}')"
public_ok="$(dump addr=127.0.0.1,user=root,host=n,laddr=127.0.0.1,lport=22 | awk '/^passwordauthentication/{print $2}')"
[ "$tailnet_ok" = yes ] || { echo "password login from the tailnet is disabled (expected yes)"; exit 1; }
[ "$public_ok" = no ] || { echo "the public door would accept passwords (expected key-only)"; exit 1; }
for u in root $NODE_USERS; do
  [ "$(sudo passwd -S "$u" 2>/dev/null | awk '{print $2}')" = P ] || { echo "no password set for $u"; exit 1; }
done
echo "policy: password from tailnet=yes, from the public door=no; accounts: root $NODE_USERS"
