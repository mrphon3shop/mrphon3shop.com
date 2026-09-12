#!/usr/bin/env bash
# ============================================================================
#  10-bootstrap.sh — turn a fresh GitHub-hosted runner into a manageable node.
#  * root SSH access with key-only auth   * tooling + status helpers
#  * netfilter hardening                  * node directories
#  Fast, idempotent, no long sleeps.
# ============================================================================
export LOG_TAG=bootstrap
. "$(dirname "$0")/lib/common.sh"
. "$SCRIPT_DIR/lib/memrepo.sh"
. "$SCRIPT_DIR/lib/sshd_policy.sh"
load_config

export NODE_RUN_SHORT="${GITHUB_RUN_ID:-local}"
NODE_STATE_DIR="$INSTALL_ROOT/state"
mkdir -p "$NODE_STATE_DIR" "$RUN_DIR"

# ---------------------------------------------------------------------------
step "1/6 directories + tooling"
mkdir -p "$WORK_DIR" "$DATA_ROOT" "$CONFIG_ROOT" "$LOG_ROOT" "$BACKUP_ROOT" "$NODE_STATE_DIR" /root/.ssh
chmod 700 /root/.ssh
if ! have jq; then sudo apt-get update -qq && sudo apt-get install -y -qq jq; fi

# age (needed to open the memory repository) — pinned in manifest/packages.lock
AGE_BIN="$(command -v age || true)"
if [ -z "$AGE_BIN" ] && [ -x /usr/local/bin/age ]; then AGE_BIN=/usr/local/bin/age; fi
export AGE_BIN

# ---------------------------------------------------------------------------
step "2/6 stage application code + helper commands"
mkdir -p "$INSTALL_ROOT/apps"
if have rsync; then
  sudo rsync -a --delete "$REPO_DIR/apps/" "$INSTALL_ROOT/apps/" 2>/dev/null || sudo cp -a "$REPO_DIR/apps/." "$INSTALL_ROOT/apps/"
else
  sudo cp -a "$REPO_DIR/apps/." "$INSTALL_ROOT/apps/"
fi
sudo chmod -R a+rX "$INSTALL_ROOT/apps"
log "applications staged in $INSTALL_ROOT/apps"

step "2b/6 install helper commands (node-status, node-apps, node-logs, node-sync)"
sudo install -m 0755 "$REPO_DIR/tools/node-status"   /usr/local/bin/node-status
sudo install -m 0755 "$REPO_DIR/tools/node-apps"     /usr/local/bin/node-apps
sudo install -m 0755 "$REPO_DIR/tools/node-logs"     /usr/local/bin/node-logs
sudo install -m 0755 "$REPO_DIR/tools/node-sync"     /usr/local/bin/node-sync
sudo install -m 0755 "$REPO_DIR/tools/node-push"     /usr/local/bin/node-push
sudo install -m 0755 "$REPO_DIR/tools/node-install"  /usr/local/bin/node-install
sudo install -m 0755 "$REPO_DIR/tools/node-remove"   /usr/local/bin/node-remove
sudo install -m 0755 "$REPO_DIR/tools/node-service"  /usr/local/bin/node-service
sudo install -m 0755 "$REPO_DIR/tools/node-secret"   /usr/local/bin/node-secret
sudo install -m 0755 "$REPO_DIR/tools/node-panel"    /usr/local/bin/node-panel

# ---------------------------------------------------------------------------
step "operator accounts"
for u in ${NODE_USERS:-mrphon user}; do
  id "$u" >/dev/null 2>&1 && { log "user $u exists"; continue; }
  sudo useradd -m -s /bin/bash -G sudo "$u" && log "created user $u (sudo, bash)"
done

# ---------------------------------------------------------------------------
step "3/6 root SSH access (key-only, prepared for Tailscale Funnel)"
AUTH_KEYS_SRC="$REPO_DIR/manifest/trust/authorized_keys"
[ -s "$AUTH_KEYS_SRC" ] || die "missing $AUTH_KEYS_SRC"
# merge (never clobber an operator key that was added manually at runtime)
touch /root/.ssh/authorized_keys
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in \#*) continue;; esac
  if ! grep -qF "$(awk '{print $2}' <<<"$line")" /root/.ssh/authorized_keys; then
    printf '%s\n' "$line" >>/root/.ssh/authorized_keys
    log "authorized_keys: added key $(awk '{print $3}' <<<"$line")"
  fi
done <"$AUTH_KEYS_SRC"
chmod 600 /root/.ssh/authorized_keys

SSHD_CONF="$SSHD_DROPIN"
sudo mkdir -p /etc/ssh/sshd_config.d
sudo tee "$SSHD_CONF" >/dev/null <<EOF
# managed by mrphon3shop.com/${NODE_HOSTNAME} — do not edit by hand
Port ${SSHD_PORT:-22}
AddressFamily any
ListenAddress 0.0.0.0
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
GSSAPIAuthentication no
UsePAM yes
AllowUsers ${NODE_USERS:-mrphon user} root
MaxAuthTries 4
MaxSessions 10
LoginGraceTime 20
ClientAliveInterval 25
ClientAliveCountMax 350
AllowTcpForwarding local
AllowAgentForwarding yes
X11Forwarding no
PermitUserEnvironment no
PrintMotd yes
PrintLastLog yes
UseDNS no
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

if ! grep -q 'sshd_config.d' /etc/ssh/sshd_config; then
  sudo sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

sudo ssh-keygen -A >/dev/null 2>&1 || true
# sshd needs its privilege separation directory before it will validate a config
sudo mkdir -p /run/sshd && sudo chmod 0755 /run/sshd

if ! sudo sshd -t 2>/tmp/sshd_test.err; then
  warn "merged sshd config is invalid, disabling the drop-in: $(head -2 /tmp/sshd_test.err)"
  sudo rm -f "$SSHD_CONF"
  if ! sudo sshd -t 2>/tmp/sshd_test2.err; then
    die "sshd configuration is broken even without the drop-in: $(head -2 /tmp/sshd_test2.err)"
  fi
  warn "continuing with the runner's stock sshd configuration"
fi

sudo systemctl start ssh >/dev/null 2>&1 || sudo systemctl start sshd >/dev/null 2>&1 || true
if ! (exec 3<>/dev/tcp/127.0.0.1/"${SSHD_PORT:-22}") 2>/dev/null; then
  sudo pkill -x sshd 2>/dev/null || true
  sudo /usr/sbin/sshd -p "${SSHD_PORT:-22}" || die "could not start sshd"
fi
exec 3>&- 2>/dev/null || true
wait_port 127.0.0.1 "${SSHD_PORT:-22}" 15 || die "sshd is not listening on ${SSHD_PORT:-22}"
log "sshd ready on port ${SSHD_PORT:-22} (public key only, root login by key)"

# ---------------------------------------------------------------------------
step "4/6 netfilter hardening (best effort)"
if have iptables && sudo iptables -L >/dev/null 2>&1; then
  sudo iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 1 -i lo -j ACCEPT
  for port in "${SSHD_PORT:-22}" "${PANEL_PORT:-8088}"; do
    # only the funnel/local path and the tailnet may reach these ports
    sudo iptables -C INPUT -p tcp --dport "$port" -s 127.0.0.1 -j ACCEPT 2>/dev/null || \
      sudo iptables -I INPUT 2 -p tcp --dport "$port" -s 127.0.0.1 -j ACCEPT
    sudo iptables -C INPUT -p tcp --dport "$port" -i tailscale0 -j ACCEPT 2>/dev/null || \
      sudo iptables -I INPUT 3 -p tcp --dport "$port" -i tailscale0 -j ACCEPT
    sudo iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || \
      sudo iptables -A INPUT -p tcp --dport "$port" -j DROP
  done
  log "netfilter: sshd/panel restricted to loopback + tailscale0"
else
  warn "iptables unavailable — relying on key-only auth + cloud firewall"
fi

# ---------------------------------------------------------------------------
step "5/6 login banner + shell helpers"
sudo tee /etc/motd >/dev/null <<EOF

  mrphon3shop node — ${NODE_HOSTNAME}.${TAILNET_DNS}
  ephemeral GitHub-hosted runner acting as a 24/7 VPS (watchdog chained)
  run id: ${GITHUB_RUN_ID:-local}   deadline: $(iso "$(deadline_epoch)")
  your data is restored from the encrypted memory repository on every boot.

  node-status   → chain, lease, funnel and app state
  node-apps     → installed applications + versions
  node-service  → start|stop|restart|status|logs <app>
  node-install  → install/attach an app (persists to the memory repo)
  node-remove   → remove an app (data kept, or --purge)
  node-push     → snapshot node state to the memory repo
  node-logs     → tail node logs

EOF
sudo tee /etc/profile.d/00-mrphon3shop.sh >/dev/null <<'EOF'
alias ll='ls -alF'
alias node='node-status'
export NODE_ROOT=/opt/mrphon3shop
EOF

# ---------------------------------------------------------------------------
step "6/6 node metadata"
jq -n --arg ts "$(iso)" --arg run "${GITHUB_RUN_ID:-local}" --arg node "$NODE_HOSTNAME" \
      --arg host "$(hostname)" --arg kernel "$(uname -r)" --arg os "$( . /etc/os-release; echo "$PRETTY_NAME" )" \
      --arg started "$(iso "$JOB_STARTED_EPOCH")" --argjson deadline "$(deadline_epoch)" \
      --argjson cpus "$(nproc)" --arg mem "$(free -m | awk '/^Mem:/{print $2}')" \
      '{node:$node, run_id:$run, runner_host:$host, kernel:$kernel, os:$os, cpus:$cpus, mem_mb:$mem,
        started_at:$started, deadline_epoch:$deadline, booted_at:$ts}' >"$NODE_STATE_DIR/meta.json"
cat "$NODE_STATE_DIR/meta.json"

log "bootstrap complete in $(( $(now) - JOB_STARTED_EPOCH ))s"
