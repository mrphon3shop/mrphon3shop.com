#!/usr/bin/env bash
# ============================================================================
#  80-state-sync.sh — snapshot everything that must outlive this runner into
#  the encrypted memory repository.  Run periodically and once more at handoff.
#    [--final]
# ============================================================================
export LOG_TAG=sync
. "$(dirname "$0")/lib/common.sh"
. "$SCRIPT_DIR/lib/memrepo.sh"
load_config

FINAL=0; [ "${1:-}" = "--final" ] && FINAL=1
START="$(now)"
NODE_STATE_DIR="$INSTALL_ROOT/state"
SVC_FILE="$REPO_DIR/manifest/services.json"
PUSHED=0; FAILED=0

[ -n "${AGE_IDENTITY_FILE:-}" ] || { warn "no age identity — state sync skipped"; exit 0; }
[ -d "$MEM_DIR/.git" ] || { warn "memory repository not initialised — state sync skipped"; exit 0; }

step "memory repo"
mem_pull || warn "pull failed; continuing"

# ---- application data + config --------------------------------------------
step "application data / config"
while read -r b64; do
  [ -z "$b64" ] && continue
  svc="$(echo "$b64" | base64 -d)"
  name="$(jq -r '.name' <<<"$svc")"
  [ "$(jq -r '.persist // true' <<<"$svc")" = "true" ] || continue
  for pair in "appdata:.data_paths" "appcfg:.config_paths"; do
    label="${pair%%:*}-${name}"; ptr="${pair#*:}"
    mapfile -t paths < <(jq -r "${ptr}[]?" <<<"$svc" | sed 's#^/##')
    [ "${#paths[@]}" -eq 0 ] && continue
    # A service that is switched off and has never written anything cannot have
    # data to store — don't report that as a failure.  (Once it has run, its
    # paths exist and are stored even while the service is off, so turning an
    # app off never loses its data.)
    state="$(jq -r '.state // ""' <<<"$svc")"
    on_disk=0
    for p in "${paths[@]}"; do [ -e "/$p" ] && { on_disk=1; break; }; done
    if [ "$on_disk" = 0 ] && { [ "$state" = "disabled" ] || [ "$state" = "setup-failed" ]; }; then
      log "nothing to store for $label ($state, no data on disk yet)"; continue
    fi
    if mem_put_blob "$label" "${paths[@]}" >/dev/null 2>&1; then
      log "stored $label (${paths[*]})"; PUSHED=$((PUSHED+1))
    else
      warn "store failed: $label"; FAILED=$((FAILED+1))
    fi
  done
done < <(jq -r '.services[]? | @base64' "$SVC_FILE")

# ---- node level state ------------------------------------------------------
step "node state (identity, sshd config, operator keys, desired delta)"
if mem_put_blob tailscale-state "var/lib/tailscale" >/dev/null 2>&1; then
  log "stored tailscale-state (identity + certificates reused by the next runner)"; PUSHED=$((PUSHED+1))
else
  warn "tailscale-state not stored (daemon may not be running yet)"; FAILED=$((FAILED+1))
fi

SYS_STAGE="$WORK_DIR/sys-stage"; rm -rf "$SYS_STAGE"; mkdir -p "$SYS_STAGE/etc/ssh/sshd_config.d" "$SYS_STAGE/etc/profile.d"
sudo cp -f /etc/ssh/sshd_config.d/00-runner-vps.conf "$SYS_STAGE/etc/ssh/sshd_config.d/" 2>/dev/null || true
sudo cp -f /root/.ssh/authorized_keys "$SYS_STAGE/root_authorized_keys" 2>/dev/null || true
# the host keys must survive the handover, otherwise every node looks like a
# different machine to the operator's ssh client
sudo cp -f /etc/ssh/ssh_host_*_key "$SYS_STAGE/etc/ssh/" 2>/dev/null || true
sudo cp -f /etc/ssh/ssh_host_*_key.pub "$SYS_STAGE/etc/ssh/" 2>/dev/null || true
sudo cp -f /etc/ssh/operator_authorized_keys "$SYS_STAGE/etc/ssh/operator_authorized_keys" 2>/dev/null || true
sudo cp -f /etc/motd "$SYS_STAGE/etc/motd" 2>/dev/null || true
if mem_put_blob system "opt/mrphon3shop/work/sys-stage" >/dev/null 2>&1; then
  log "stored system config (sshd drop-in, root keys, motd)"; PUSHED=$((PUSHED+1))
else
  warn "system config store failed"; FAILED=$((FAILED+1))
fi

if [ -s "$NODE_STATE_DIR/desired.json" ]; then
  mkdir -p "$WORK_DIR/desired_blob"
  cp -f "$NODE_STATE_DIR/desired.json" "$WORK_DIR/desired_blob/desired.json"
  if mem_put_blob desired "opt/mrphon3shop/work/desired_blob" >/dev/null 2>&1; then
    log "stored operator desired-state"; PUSHED=$((PUSHED+1))
  fi
fi

# ---- publish --------------------------------------------------------------
step "publish ($PUSHED blob(s), $FAILED failure(s))"
if mem_commit_push "sync(${NODE_HOSTNAME}): run ${MY_RUN:-local}${FINAL:+ final} — ${PUSHED} blob(s)" blobs manifest state; then
  log "memory repository updated"
else
  warn "memory repository push failed — data remains available on this node"
fi

jq -n --arg ts "$(iso)" --argjson pushed "$PUSHED" --argjson failed "$FAILED" --argjson secs "$(( $(now) - START ))" \
      --argjson final "$FINAL" '{at:$ts, blobs_pushed:$pushed, blobs_failed:$failed, seconds:$secs, final:($final==1)}' \
  >"$NODE_STATE_DIR/last_sync.json"
log "state sync finished in $(( $(now) - START ))s"
