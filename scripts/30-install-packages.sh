#!/usr/bin/env bash
# ============================================================================
#  30-install-packages.sh — converge the node to the declared software state.
#    * reads manifest/packages.lock (repo, pinned)  + desired.json (memory repo)
#    * installs only what is missing/out-of-date   (fast: no reinstall churn)
#    * records every resolved version into the encrypted inventory
#    * detects removals (unmanaged-in-memory) and de-installs them
# ============================================================================
export LOG_TAG=install
. "$(dirname "$0")/lib/common.sh"
. "$SCRIPT_DIR/lib/memrepo.sh"
load_config

START="$(now)"
NODE_STATE_DIR="$INSTALL_ROOT/state"
INVENTORY="$NODE_STATE_DIR/inventory.json"
DESIRED="$NODE_STATE_DIR/desired.json"
[ -s "$DESIRED" ] || echo '{"add":[],"remove":[]}' >"$DESIRED"
LOCK="$REPO_DIR/manifest/packages.lock"

INV_TMP="$(mktemp)"; echo '{"packages":[],"generated_at":"","node":"","drift":[],"removed":[]}' >"$INV_TMP"

_apt_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------- helpers ---
record() { # kind name requested installed status [note]
  local kind="$1" name="$2" req="$3" got="$4" st="$5" note="${6:-}"
  local t; t="$(mktemp)"
  jq --arg k "$kind" --arg n "$name" --arg r "$req" --arg g "$got" --arg s "$st" --arg note "$note" \
     '.packages += [{kind:$k,name:$n,requested:$r,installed:$g,status:$s,note:$note}]' "$INV_TMP" >"$t" && mv "$t" "$INV_TMP"
  printf '  %-8s %-22s %-14s %s %s\n' "$kind" "$name" "${got:-$req}" "$st" "$note" >&2
}

apt_want_install() { # name req  -> should we install?
  local name="$1" req="$2" cur; cur="$(_apt_version "$name")"
  if [ -z "$cur" ]; then return 0; fi
  case "$req" in
    any|"") return 1 ;;
    ">="*) [ "$(dpkg --compare-versions "$cur" ge "${req#>*=}" && echo ok)" = ok ] && return 1 || return 0 ;;
    *) [ "$cur" = "$req" ] && return 1 || return 0 ;;
  esac
}

# ---------------------------------------------------------------- apt -------
step "apt packages (manifest/packages.lock + memory delta)"
APT_MISSING=()
while IFS=$'\t' read -r kind name spec group; do
  case "$kind" in ''|\#*) continue;; esac
  [ "$kind" = apt ] || continue
  [ "${group:-core}" = extra ] && [ "${INSTALL_EXTRA:-1}" = 0 ] && { log "skip extra: $name"; continue; }
  req="$spec"
  if apt_want_install "$name" "$req"; then APT_MISSING+=("$name"); fi
done <"$LOCK"

# operator-added packages from the memory repo
while read -r name spec; do
  [ -z "$name" ] && continue
  if apt_want_install "$name" "$spec"; then APT_MISSING+=("$name"); fi
done < <(jq -r '.add[]? | select(.kind=="apt") | "\(.name) \(.spec // "any")"' "$DESIRED")

if [ "${#APT_MISSING[@]}" -gt 0 ]; then
  log "apt-get install: ${APT_MISSING[*]}"
  sudo apt-get update -qq >/dev/null 2>&1 || warn "apt-get update failed (continuing with cached indexes)"
  # one pass, no interactive prompts, no recommends -> fast
  sudo apt-get install -y -qq --no-install-recommends "${APT_MISSING[@]}" >/tmp/apt.log 2>&1 || {
    warn "single-pass install failed, retrying package by package"
    for p in "${APT_MISSING[@]}"; do
      sudo apt-get install -y -qq --no-install-recommends "$p" >/tmp/apt.log 2>&1 || warn "apt install failed: $p ($(tail -1 /tmp/apt.log))"
    done
  }
else
  log "all apt packages already satisfied"
fi

while IFS=$'\t' read -r kind name spec group; do
  case "$kind" in ''|\#*) continue;; esac
  [ "$kind" = apt ] || continue
  if [ "${group:-core}" = extra ] && [ "${INSTALL_EXTRA:-1}" = 0 ]; then record apt "$name" "$spec" "" SKIPPED "extra group disabled"; continue; fi
  cur="$(_apt_version "$name")"
  if [ -z "$cur" ]; then record apt "$name" "$spec" "" "MISSING" "not installed"; continue; fi
  case "$spec" in
    any|"") record apt "$name" "$spec" "$cur" OK ;;
    ">="*) if [ "$(dpkg --compare-versions "$cur" ge "${spec#>*=}" && echo ok)" = ok ]; then record apt "$name" "$spec" "$cur" OK; else record apt "$name" "$spec" "$cur" DRIFT "below minimum"; fi ;;
    *) [ "$cur" = "$spec" ] && record apt "$name" "$spec" "$cur" OK || record apt "$name" "$spec" "$cur" DRIFT "pin mismatch" ;;
  esac
done <"$LOCK"

while read -r name spec; do
  [ -z "$name" ] && continue
  record apt "$name" "$spec (memory)" "$(_apt_version "$name")" OK "operator-installed"
done < <(jq -r '.add[]? | select(.kind=="apt") | "\(.name) \(.spec // "any")"' "$DESIRED")

# ---------------------------------------------------------------- binaries --
step "pinned binaries"
while IFS=$'\t' read -r kind name spec group; do
  case "$kind" in ''|\#*) continue;; esac
  [ "$kind" = bin ] || continue
  want_ver="${spec%%|*}"; url="${spec#*|}"
  cur=""
  case "$name" in
    age) [ -x /usr/local/bin/age ] && cur="$(/usr/local/bin/age --version 2>/dev/null | sed 's/^v//')" ;;
    age-keygen) [ -x /usr/local/bin/age-keygen ] && cur="$(/usr/local/bin/age-keygen --version 2>/dev/null | sed 's/^v//')" ;;
    *)  have "$name" && cur="$(command -v "$name" >/dev/null && "$name" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)" ;;
  esac
  if [ "$cur" = "$want_ver" ]; then record bin "$name" "$want_ver" "$cur" OK; continue; fi

  tmpd="$(mktemp -d)"
  log "fetching $name $want_ver"
  if retry 2 2 curl -fsSL --max-time 60 -o "$tmpd/pkg" "$url" >/dev/null 2>&1; then
    case "$url" in
      *.tar.gz|*.tgz) tar -xzf "$tmpd/pkg" -C "$tmpd" ;;
      *) chmod +x "$tmpd/pkg" ;;
    esac
    bin="$(find "$tmpd" -type f -name "$name" -perm -u+x | head -1)"
    if [ -n "$bin" ]; then
      sudo install -m 0755 "$bin" "/usr/local/bin/$name"
      cur="$("/usr/local/bin/$name" --version 2>/dev/null | sed 's/^v//' | head -1)"
      record bin "$name" "$want_ver" "$cur" OK
    else
      record bin "$name" "$want_ver" "" "FAILED" "binary not found in archive"
    fi
  else
    record bin "$name" "$want_ver" "$cur" "FAILED" "download failed"
  fi
  rm -rf "$tmpd"
done <"$LOCK"

# ---------------------------------------------------------------- scripts ---
step "installer scripts (tailscale)"
while IFS=$'\t' read -r kind name spec group; do
  case "$kind" in ''|\#*) continue;; esac
  [ "$kind" = script ] || continue
  if have tailscale && [ "$name" = tailscale ]; then
    record script "$name" "${spec%%|*}" "$(tailscale version 2>/dev/null | head -1)" OK
    continue
  fi
  url_of="${spec#*|}"
  log "running installer for $name"
  if retry 2 3 bash -c "curl -fsSL '$url_of' | sh" >/tmp/${name}_install.log 2>&1 && have "$name"; then
    record script "$name" "${spec%%|*}" "$(tailscale version 2>/dev/null | head -1)" OK
  else
    record script "$name" "${spec%%|*}" "" FAILED "installer failed"
  fi
done <"$LOCK"

# ---------------------------------------------------------------- removals --
step "removals requested from the memory repo (uninstall = intent)"
while read -r name; do
  [ -z "$name" ] && continue
  case "$name" in openssh-server|curl|ca-certificates|iptables|procps|rsync) warn "protected package, refusing to remove: $name"; continue;; esac
  if [ -n "$(_apt_version "$name")" ]; then
    sudo apt-get remove -y -qq "$name" >/dev/null 2>&1 && record apt "$name" "removed (memory)" "" REMOVED "operator-uninstalled" || record apt "$name" "removed (memory)" "$(_apt_version "$name")" "FAILED" "apt remove failed"
  fi
done < <(jq -r '.remove[]? // empty' "$DESIRED")

# ---------------------------------------------------------------- inventory -
step "inventory"
jq --arg ts "$(iso)" --arg node "$NODE_HOSTNAME" --argjson secs "$(( $(now) - START ))" \
   --arg run "${GITHUB_RUN_ID:-local}" --arg os "$( . /etc/os-release; echo "$PRETTY_NAME" )" \
   '.generated_at=$ts | .node=$node | .run_id=$run | .os=$os | .install_seconds=$secs
    | .drift = [ .packages[] | select(.status!="OK") ]
    | .count = (.packages|length)' "$INV_TMP" >"$INVENTORY"
jq -r '"  installed=\(.count)  drift=\(.drift|length)  seconds=\(.install_seconds)"' "$INVENTORY" >&2
jq -r '.drift[]? | "  DRIFT: \(.kind) \(.name) requested=\(.requested) installed=\(.installed) [\(.status)] \(.note)"' "$INVENTORY" >&2

# write-through to memory repo (encrypted) — this is what makes changes stick
mkdir -p "$WORK_DIR/inventory_blob"
cp "$INVENTORY" "$WORK_DIR/inventory_blob/inventory.json"
if [ -n "${AGE_IDENTITY_FILE:-}" ] && [ -d "$MEM_DIR/.git" ]; then
  mem_pull
  mem_put_blob inventory "opt/mrphon3shop/state/inventory.json" >/dev/null && \
    mem_commit_push "inventory(${NODE_HOSTNAME}): ${GITHUB_RUN_ID:-local}" blobs manifest && log "inventory pushed to memory repo"
else
  warn "inventory kept local (memory credentials not available)"
fi
log "package convergence finished in $(( $(now) - START ))s"
