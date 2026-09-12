# shellcheck shell=bash
# ============================================================================
#  sshd_policy.sh — the single place that decides who may authenticate how.
#
#  Global policy  : keys only (PasswordAuthentication no, root prohibit-password)
#  Match block    : passwords are accepted from inside the tailnet
#                   (100.64.0.0/10 + fd7a:115c:a1e0::/48) only.
#
#  Why a Match block: the public Funnel door arrives on loopback (the relay
#  connects to tcp://127.0.0.1:22), so a public visitor can never reach a
#  password prompt, while a tailnet peer — already WireGuard-authenticated and
#  a device you own — can log in with a password. Read docs/SECURITY.md.
# ============================================================================
SSHD_DROPIN="${SSHD_DROPIN:-/etc/ssh/sshd_config.d/00-runner-vps.conf}"
SSHD_MATCH_MARK="# ---- password door: inside the tailnet only ----"
TAILNET_CIDR="100.64.0.0/10,fd7a:115c:a1e0::/48"

ensure_sshd_rundir() { # `sshd -t`/`sshd -T` need it; a stopped sshd has not created it
  [ -d /run/sshd ] && return 0
  sudo mkdir -p /run/sshd 2>/dev/null && sudo chmod 0755 /run/sshd 2>/dev/null
}

sshd_dump() { # [ -C "addr=...,user=...,host=...,laddr=...,lport=..." ] -> config on stdout
  # `sshd -T` refuses to run without the privilege separation directory, which
  # exists on a booted host only because the ssh service creates it.  A fresh
  # container or a runner whose sshd has not started yet has no /run/sshd, and
  # the probe then fails with an empty result — create it and try once more.
  local spec="${1:-}" errf out
  errf="$(mktemp)"; # shellcheck disable=SC2064
  trap "rm -f '$errf'" RETURN
  for _ in 1 2; do
    if [ -n "$spec" ]; then out="$(sudo sshd -T -C "$spec" 2>"$errf")"; else out="$(sudo sshd -T 2>"$errf")"; fi
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    if grep -qi 'privilege separation' "$errf"; then
      ensure_sshd_rundir
    else
      break
    fi
  done
  warn "  sshd -T ${spec:+(-C) }failed: $(head -1 "$errf")"
  return 1
}

write_sshd_policy() {
  local users="${NODE_USERS:-mrphon user}" public_pw="${ALLOW_PUBLIC_PASSWORD:-false}"
  # keep only the part above our match block: the block is rebuilt every time
  if sudo test -s "$SSHD_DROPIN"; then
    sudo sed -i "/^${SSHD_MATCH_MARK//\//\\/}/,\$d" "$SSHD_DROPIN" 2>/dev/null || true
  fi
  sudo sed -i "s/^AllowUsers .*/AllowUsers ${users} root/" "$SSHD_DROPIN" 2>/dev/null || true
  # a global AuthenticationMethods makes `AuthenticationMethods any` illegal in
  # the Match block, and it is redundant while PasswordAuthentication is no
  sudo sed -i '/^AuthenticationMethods /d' "$SSHD_DROPIN" 2>/dev/null || true

  if [ "$public_pw" = "true" ]; then
    warn "ALLOW_PUBLIC_PASSWORD=true — the PUBLIC door will accept the password too"
    sudo sed -i 's/^PasswordAuthentication .*/PasswordAuthentication yes/' "$SSHD_DROPIN"
    sudo sed -i 's/^KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' "$SSHD_DROPIN"
    sudo sed -i 's/^PermitRootLogin .*/PermitRootLogin yes/' "$SSHD_DROPIN"
  else
    sudo tee -a "$SSHD_DROPIN" >/dev/null <<MATCH
${SSHD_MATCH_MARK}
Match Address ${TAILNET_CIDR}
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    PermitRootLogin yes
    AuthenticationMethods any
    MaxAuthTries 4
MATCH
  fi
}

reload_sshd() {
  ensure_sshd_rundir
  sudo sshd -t 2>/tmp/sshd_test.err || die "sshd config invalid: $(head -2 /tmp/sshd_test.err | tr '\n' ' ')"
  sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null \
    || sudo pkill -HUP -x sshd 2>/dev/null || true
}

verify_sshd_policy() { # prints one line per source address, 0 = all as intended
  local rc=0 addr want got
  for pair in "100.66.254.29:yes" "127.0.0.1:$([ "${ALLOW_PUBLIC_PASSWORD:-false}" = true ] && echo yes || echo no)" \
              "203.0.113.7:$([ "${ALLOW_PUBLIC_PASSWORD:-false}" = true ] && echo yes || echo no)"; do
    addr="${pair%%:*}"; want="${pair##*:}"
    got="$(sshd_dump "addr=$addr,user=root,host=node,laddr=$addr,lport=22" \
          | awk '/^passwordauthentication/{print $2}')"
    if [ "$got" = "$want" ]; then
      log "  from $addr -> PasswordAuthentication=$got (as intended)"
    else
      warn "  from $addr -> PasswordAuthentication=${got:-?} (expected $want)"; rc=1
    fi
  done
  return "$rc"
}
