#!/usr/bin/env bash
# ============================================================================
#  15-passwords.sh — password access, scoped to the private tailnet.
#
#  Policy (see docs/SECURITY.md):
#    * from anywhere else (the public Funnel door, which arrives on loopback)
#      authentication stays key-only;
#    * from addresses inside your Tailscale tailnet (100.64.0.0/10 and the
#      Tailscale IPv6 range) the operator can log in with a password — those
#      packets are already WireGuard-encrypted and only your own devices can
#      send them.
#
#  The password itself comes from the ROOT_PASSWORD secret, is piped straight
#  into chpasswd and is never written to a log, an argument list or a file.
# ============================================================================
export LOG_TAG=passwd
. "$(dirname "$0")/lib/common.sh"
. "$SCRIPT_DIR/lib/sshd_policy.sh"
load_config

SSHD_CONF_DIR=/etc/ssh/sshd_config.d
DROPIN="$SSHD_CONF_DIR/00-runner-vps.conf"
MATCH_MARK="# ---- password door: inside the tailnet only ----"

# the tailnet ranges: 100.64.0.0/10 (IPv4) and fd7a:115c:a1e0::/48 (IPv6)
TAILNET_MATCH="100.64.0.0/10,fd7a:115c:a1e0::/48"

step "operator accounts"
USERS="${NODE_USERS:-mrphon user}"
for u in $USERS; do
  if id "$u" >/dev/null 2>&1; then
    log "user $u already exists"
  else
    sudo useradd -m -s /bin/bash -G sudo "$u"
    log "created user $u (sudo, bash)"
  fi
  # passwordless-typo protection: an operator account must still need a password
  sudo passwd -u "$u" >/dev/null 2>&1 || true
done

if [ -z "${ROOT_PASSWORD:-}" ]; then
  warn "ROOT_PASSWORD is not set — leaving passwords untouched (key-only access stays available)"
else
  step "set the operator password (value never logged)"
  {
    printf 'root:%s\n' "$ROOT_PASSWORD"
    for u in $USERS; do printf '%s:%s\n' "$u" "$ROOT_PASSWORD"; done
  } | sudo chpasswd
  unset ROOT_PASSWORD
  for u in root $USERS; do
    state="$(sudo passwd -S "$u" | awk '{print $2}')"
    case "$state" in
      P|P*) log "password set for $u" ;;
      *)    warn "password state for $u is '$state' — check chpasswd" ;;
    esac
  done
fi

step "sshd policy: key-only in public, password inside the tailnet"
write_sshd_policy
reload_sshd
log "sshd policy written and reloaded"

step "verify the effective policy per source address"
if verify_sshd_policy; then
  echo "::notice title=SSH access::passwords work inside the tailnet; the public door stays key-only"
else
  warn "some addresses do not match the intended policy — inspect $SSHD_DROPIN"
fi
log "password stage finished"
