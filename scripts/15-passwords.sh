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
sudo mkdir -p "$SSHD_CONF_DIR"
# rebuild the drop-in without the old match block, then append the current one
if [ -s "$DROPIN" ]; then
  sudo sed -i "/^${MATCH_MARK//\//\\/}/,\$d" "$DROPIN" 2>/dev/null || true
fi
sudo sed -i 's/^AllowUsers .*/AllowUsers root '"$USERS"'/' "$DROPIN" 2>/dev/null || true
# OpenSSH refuses `AuthenticationMethods any` inside a Match block when a global
# AuthenticationMethods is present: the global one is redundant here anyway
# (PasswordAuthentication no already forces keys), so drop it.
sudo sed -i '/^AuthenticationMethods /d' "$DROPIN" 2>/dev/null || true

if [ "${ALLOW_PUBLIC_PASSWORD:-false}" = "true" ]; then
  warn "ALLOW_PUBLIC_PASSWORD=true — the PUBLIC Funnel door will accept the password too (see docs/SECURITY.md)"
  sudo sed -i 's/^PasswordAuthentication .*/PasswordAuthentication yes/' "$DROPIN"
  sudo sed -i 's/^KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' "$DROPIN"
  sudo sed -i 's/^AuthenticationMethods .*/AuthenticationMethods any/' "$DROPIN"
  sudo sed -i 's/^PermitRootLogin .*/PermitRootLogin yes/' "$DROPIN"
else
  sudo tee -a "$DROPIN" >/dev/null <<EOF

$MATCH_MARK
Match Address $TAILNET_MATCH
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    PermitRootLogin yes
    AuthenticationMethods any
    MaxAuthTries 4
EOF
  log "password authentication enabled for tailnet sources only"
fi

if sudo sshd -t 2>/tmp/sshd_test.err; then
  sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || sudo pkill -HUP -x sshd 2>/dev/null || true
  log "sshd config valid and reloaded"
else
  die "sshd config is invalid: $(head -2 /tmp/sshd_test.err | tr '\n' ' ')"
fi

step "verify the effective policy per source address"
verify() { # verify <addr> <expected passwordauth>
  local addr="$1" want="$2" got
  got="$(sudo sshd -T -C "addr=$addr,user=root,host=node,laddr=$addr,lport=22" 2>/dev/null \
        | awk -F' ' '/^passwordauthentication/{print $2}')"
  if [ "$got" = "$want" ]; then
    log "from $addr -> PasswordAuthentication=$got (as intended)"
  else
    warn "from $addr -> PasswordAuthentication=$got (expected $want)"
    return 1
  fi
}
rc=0
verify 100.66.254.29 yes || rc=1     # a tailnet peer
verify 127.0.0.1 no      || rc=1     # the public Funnel door (arrives on loopback)
verify 203.0.113.7 no    || rc=1     # the open internet, directly
if [ "$rc" = 0 ]; then
  echo "::notice title=SSH access::passwords work inside the tailnet; the public door stays key-only"
else
  warn "some source addresses do not match the intended policy — inspect sshd_config.d/00-runner-vps.conf"
fi
log "password stage finished"
