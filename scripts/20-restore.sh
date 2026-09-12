#!/usr/bin/env bash
# ============================================================================
#  20-restore.sh — bring back everything the previous runner owned:
#    * encrypted app data + config from the memory repository
#    * Tailscale node identity/certificates (so the Funnel name is reused)
#    * operator-desired package delta (signed) -> consumed by 30-install-packages
#  Never fails the boot because of a bad blob: it degrades and reports.
# ============================================================================
export LOG_TAG=restore
. "$(dirname "$0")/lib/common.sh"
. "$SCRIPT_DIR/lib/memrepo.sh"
load_config

START="$(now)"
NODE_STATE_DIR="$INSTALL_ROOT/state"
mkdir -p "$NODE_STATE_DIR"

step "memory repository"
mem_init || die "memory repo unavailable"
mem_pull
git -C "$MEM_DIR" log --oneline -1 | sed 's/^/  head: /'

# ---- integrity gate --------------------------------------------------------
step "verify signed blob index"
ALLOWED="$REPO_DIR/manifest/trust/allowed_signers"
TRUST=0
if mem_verify "$MEM_DIR/manifest/blobs.json" "$ALLOWED"; then
  TRUST=1; log "blob index signature: VALID ($(jq -r '.seq // 0' "$MEM_DIR/manifest/blobs.json") entries seq / $(jq -r '.blobs|length' "$MEM_DIR/manifest/blobs.json") blobs)"
else
  warn "blob index signature could not be verified — restoring only blobs that decrypt cleanly"
fi
echo "$TRUST" >"$NODE_STATE_DIR/index_trusted"

# ---- Tailscale identity (must happen before 50-tailscale-funnel.sh) --------
step "Tailscale identity + certificates"
if mem_blob_exists tailscale-state; then
  if mem_get_blob tailscale-state /; then
    sudo chown -R root:root /var/lib/tailscale 2>/dev/null || true
    log "tailscale state restored ($(du -sh /var/lib/tailscale 2>/dev/null | cut -f1)) — node identity and TLS certs reused"
  else
    warn "tailscale state restore failed — node will re-register with the auth key"
  fi
else
  log "no stored tailscale state yet (first boot of the chain)"
fi

# ---- applications ----------------------------------------------------------
step "applications declared in manifest/services.json"
RESTORED=0; FAILED=0
mapfile -t SERVICES < <(jq -r '.services[]? | @base64' "$REPO_DIR/manifest/services.json" 2>/dev/null || true)
for b64 in "${SERVICES[@]}"; do
  [ -z "$b64" ] && continue
  svc="$(echo "$b64" | base64 -d)"
  name="$(jq -r '.name' <<<"$svc")"
  persist="$(jq -r '.persist // true' <<<"$svc")"
  [ "$persist" = "true" ] || { log "skip $name (persist=false)"; continue; }

  for kind in appdata appcfg; do
    label="${kind}-${name}"
    mem_blob_exists "$label" || continue
    if mem_get_blob "$label" /; then
      log "restored $label"; RESTORED=$((RESTORED+1))
    else
      warn "restore failed: $label"; FAILED=$((FAILED+1))
    fi
  done
done
log "restored ${RESTORED} app blob(s), ${FAILED} failure(s)"

# ---- operator-desired package delta ---------------------------------------
step "desired package state (operator intent from the memory repo)"
DESIRED="$NODE_STATE_DIR/desired.json"
if mem_blob_exists desired; then
  tmpd="$(mktemp -d)"
  if mem_get_blob desired "$tmpd" && [ -s "$tmpd/desired.json" ]; then
    # prevent privilege escalation through the memory repo: the delta may only
    # contain apt/bin entries (never scripts), and only verifiable JSON.
    jq -e 'all(.add[]?; (.kind=="apt" or .kind=="bin"))' "$tmpd/desired.json" >/dev/null 2>&1 || die "desired.json contains a non-installable kind — refusing"
    jq -e 'all(.add[]?.name; test("^[a-zA-Z0-9][a-zA-Z0-9.+-]*$"))' "$tmpd/desired.json" >/dev/null 2>&1 || die "desired.json contains a suspicious package name — refusing"
    cp "$tmpd/desired.json" "$DESIRED"
    log "desired delta accepted: $(jq -r '.add|length' "$DESIRED") add, $(jq -r '.remove|length' "$DESIRED") remove"
  else
    warn "desired blob unusable"; echo '{"add":[],"remove":[]}' >"$DESIRED"
  fi
  rm -rf "$tmpd"
else
  echo '{"add":[],"remove":[]}' >"$DESIRED"
fi

# ---- previous inventory (drift detection) ---------------------------------
if mem_blob_exists inventory; then
  tmpd="$(mktemp -d)"
  mem_get_blob inventory "$tmpd" && cp -f "$tmpd/inventory.json" "$NODE_STATE_DIR/inventory.prev.json" 2>/dev/null || true
  rm -rf "$tmpd"
fi

END="$(now)"
jq -n --argjson seconds "$((END-START))" --argjson trust "$TRUST" --argjson restored "$RESTORED" --argjson failed "$FAILED" \
  '{restore_seconds:$seconds, index_signature_trusted:($trust==1), blobs_restored:$restored, blobs_failed:$failed}' \
  >"$NODE_STATE_DIR/restore.json"
log "restore finished in $((END-START))s"
