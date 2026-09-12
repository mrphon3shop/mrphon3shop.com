#!/usr/bin/env bash
# ============================================================================
#  memrepo.sh — memory-repository client: encrypted blob transport + signed
#  plaintext state.  Sourced after common.sh.
#
#  Layout inside the memory repository (public repo, everything sensitive is
#  age-encrypted, plaintext state files are signed with the fleet key):
#     state/lease.json      state/lease.json.sig
#     state/heartbeat.json  state/heartbeat.json.sig
#     state/handoff.json    state/handoff.json.sig
#     state/nodes.jsonl
#     manifest/blobs.json   manifest/blobs.json.sig      (hash index, verified)
#     blobs/<name>.tar.zst.age                            (age encrypted)
# ============================================================================

MEM_DIR="${MEM_DIR:-${WORK:-/opt/mrphon3shop/work}/mem}"
MEM_URL="${MEM_URL:-}"
MEM_SIG_NS="fleet-manifest"

# ------------------------------------------------------------- bootstrap ----
mem_init() {
  local url
  if [ -n "$MEM_URL" ] && [ -d "$MEM_URL/.git" ]; then MEM_DIR="$MEM_URL"; return 0; fi
  if [ -d "$MEM_DIR/.git" ]; then mem_remote_ok || return 1; return 0; fi
  rm -rf "$MEM_DIR"
  retry 3 3 git -c "http.https://github.com/.extraheader=$(mem_auth_header)" \
        clone --depth 1 --quiet "$(mem_git_url)" "$MEM_DIR" \
    || retry 3 3 git clone --depth 1 --quiet "$(mem_git_url)" "$MEM_DIR" \
    || die "cannot clone memory repo"
  mem_git_identity
}

mem_git_url() {
  # The remote URL NEVER carries a credential: `git remote -v` is a command any
  # operator (or a leaked log) can run, so the token travels in a per-command
  # HTTP header instead and is never written to disk.
  [ -n "${MEMORY_OWNER:-}" ] && [ -n "${MEMORY_REPO:-}" ] \
    || die "MEMORY_OWNER/MEMORY_REPO are not set — refusing to guess the memory repository"
  printf 'https://github.com/%s/%s.git' "${MEMORY_OWNER}" "${MEMORY_REPO}"
}

mem_auth_header() { # Authorization header value, empty without a token
  [ -n "${MEMORY_PAT:-}" ] || return 0
  printf 'Authorization: Basic %s' "$(printf 'x-access-token:%s' "$MEMORY_PAT" | base64 | tr -d '\n')"
}

mem_git() { # mem_git <git args…>  — git in the memory repo, authenticated per call
  local hdr; hdr="$(mem_auth_header)"
  if [ -n "$hdr" ]; then
    git -C "$MEM_DIR" -c "http.https://github.com/.extraheader=$hdr" "$@"
  else
    git -C "$MEM_DIR" "$@"
  fi
}

mem_remote_ok() { git -C "$MEM_DIR" remote -v >/dev/null 2>&1; }

mem_git_identity() {
  git -C "$MEM_DIR" config user.name  "node-${NODE_HOSTNAME:-node}" >/dev/null
  git -C "$MEM_DIR" config user.email "${MEMORY_OWNER}@users.noreply.github.com" >/dev/null
}

mem_set_remote_auth() {
  # scrub any credential that an earlier version of this script embedded in the
  # remote URL, and make sure the remote is the canonical GitHub one
  local cur want; cur="$(git -C "$MEM_DIR" remote get-url origin 2>/dev/null || echo)"
  want="$(mem_git_url)" || return 0
  case "$want" in
    https://github.com/*/*.git) ;;
    *) warn "memory URL looks wrong ($want) — leaving the remote alone"; return 0 ;;
  esac
  # Is the current URL usable at all?  An empty or dangling one makes every
  # pull and push fail with a confusing "'origin' does not appear to be a git
  # repository", and the node then silently stops publishing its state.
  local usable=0
  case "$cur" in
    https://*|http://*|ssh://*|git@*) usable=1 ;;
    *) if [ -e "$cur" ] && git -C "$cur" rev-parse --git-dir >/dev/null 2>&1; then usable=1; fi ;;
  esac
  if [ "$usable" = 0 ]; then
    warn "memory remote URL is not usable (\"$cur\") — resetting it"
    git -C "$MEM_DIR" remote set-url origin "$want" 2>/dev/null || \
      git -C "$MEM_DIR" remote add origin "$want" 2>/dev/null || true
    return 0
  fi
  case "$cur" in
    *github.com*) [ "$cur" = "$want" ] || git -C "$MEM_DIR" remote set-url origin "$want" ;;
  esac
  return 0
}

mem_pull() {
  mem_init || return 1
  mem_set_remote_auth
  retry 4 2 mem_git pull --rebase --quiet origin "${MEMORY_BRANCH:-main}" >/dev/null 2>&1 || true
}

# mem_commit_push "<msg>" [paths...]  — optimistic-concurrency safe
mem_commit_push() {
  local msg="$1"; shift
  mem_set_remote_auth
  git -C "$MEM_DIR" add -A "$@" >/dev/null 2>&1 || git -C "$MEM_DIR" add -A
  if git -C "$MEM_DIR" diff --cached --quiet; then log "mem: nothing to push"; return 0; fi
  git -C "$MEM_DIR" commit -q -m "$msg" >/dev/null
  local i
  for i in 1 2 3 4 5; do
    if mem_git push --quiet origin "HEAD:${MEMORY_BRANCH:-main}" >/dev/null 2>&1; then return 0; fi
    warn "mem push rejected (attempt $i) — rebasing"
    if ! mem_git pull --rebase --quiet origin "${MEMORY_BRANCH:-main}" >/dev/null 2>&1; then
      # Somebody else advanced the branch *and* touched a generated file — in
      # practice always manifest/blobs.json.  Rebase again, preferring our side,
      # then re-derive the index from every blob on disk so nothing the other
      # writer stored is forgotten.
      mem_git rebase --abort >/dev/null 2>&1 || true
      if mem_git pull --rebase -X theirs --quiet origin "${MEMORY_BRANCH:-main}" >/dev/null 2>&1; then
        local upstream; upstream="$(mktemp)"
        mem_git show "origin/${MEMORY_BRANCH:-main}:manifest/blobs.json" >"$upstream" 2>/dev/null || true
        if mem_reindex_from_disk; then
          if [ -s "$upstream" ]; then      # union: their entries, ours winning per label
            local merged; merged="$(mktemp)"
            if jq -s '.[0] as $up | .[1] as $us
                      | {seq: ([($up.seq // 0), ($us.seq // 0)] | max),
                         updated_at: ($us.updated_at // $up.updated_at),
                         blobs: (($up.blobs // {}) + ($us.blobs // {}))}' \
                    "$upstream" "$MEM_DIR/manifest/blobs.json" >"$merged"; then
              mv "$merged" "$MEM_DIR/manifest/blobs.json" && mem_sign "$MEM_DIR/manifest/blobs.json" || true
            fi
            rm -f "$merged"
          fi
          git -C "$MEM_DIR" add manifest/blobs.json manifest/blobs.json.sig >/dev/null 2>&1 || true
          git -C "$MEM_DIR" diff --cached --quiet || \
            git -C "$MEM_DIR" commit -q -m "mem: rebuild blob index after a concurrent write" >/dev/null
        fi
        rm -f "$upstream"
      else
        mem_git rebase --abort >/dev/null 2>&1 || true
      fi
    fi
    sleep 2
  done
  warn "mem push failed after 5 attempts"
  return 1
}

# ------------------------------------------------------------- signing ------
_fleet_key_write() { # materialise the signing key from the secret, 0600, outside the repo
  local kf="$RUN_DIR/.fleet_sign" src="${FLEET_SIGN_FILE:-}"
  [ -s "$kf" ] && { printf '%s' "$kf"; return 0; }
  # prepare.sh stages the key as a 0600 file and exports its path; a step that
  # inherits FLEET_SIGN_FILE but not the raw secret must still be able to sign.
  if [ -z "${FLEET_SIGN_KEY:-}" ] && [ -n "$src" ] && [ -s "$src" ]; then
    FLEET_SIGN_KEY="$(cat "$src")"
  fi
  [ -n "${FLEET_SIGN_KEY:-}" ] || return 1
  umask 077; printf '%s\n' "$FLEET_SIGN_KEY" >"$kf"; chmod 600 "$kf"
  printf '%s' "$kf"
}

mem_sign() { # mem_sign <file>   -> writes <file>.sig
  local f="$1" kf
  kf="$(_fleet_key_write)" || { warn "no fleet signing key — skipping signature for $(basename "$1")"; return 0; }
  # ssh-keygen prompts before overwriting an existing signature (and silently
  # keeps the stale one when stdin is not a tty) — always start from a clean slate
  rm -f "$f.sig"
  ssh-keygen -Y sign -q -f "$kf" -n "$MEM_SIG_NS" "$f" </dev/null >/dev/null 2>&1 || { warn "sign failed: $f"; return 1; }
  [ -s "$f.sig" ] || { warn "no signature produced for $(basename "$f")"; return 1; }
}

mem_verify() { # mem_verify <file> <allowed_signers>  -> 0 ok / 1 bad
  local f="$1" signers="$2"
  [ -f "$f.sig" ] || { warn "unsigned: $(basename "$f")"; return 1; }
  [ -f "$signers" ] || { warn "no allowed_signers at $signers"; return 1; }
  ssh-keygen -Y verify -q -f "$signers" -I fleet -n "$MEM_SIG_NS" -s "$f.sig" <"$f" >/dev/null 2>&1
}

# ------------------------------------------------------------- blobs --------
# integrity index: manifest/blobs.json (signed) holds sha256 of every blob
_blob_index() { printf '%s' "$MEM_DIR/manifest/blobs.json"; }

mem_index_refresh() { mem_pull >/dev/null 2>&1 || true; }

mem_index_get() { local n="$1"; jq -r --arg n "$n" '.blobs[$n].sha256 // empty' "$(_blob_index)" 2>/dev/null || true; }

mem_index_put() { # mem_index_put <name> <sha256> <size> <kind>
  local n="$1" h="$2" s="$3" k="${4:-data}" idx; idx="$(_blob_index)"
  mkdir -p "$(dirname "$idx")"; [ -s "$idx" ] || echo '{"seq":0,"blobs":{}}' >"$idx"
  local repo_rev; repo_rev="$(git -C "$MEM_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  local tmp; tmp="$(mktemp)"
  jq --arg n "$n" --arg h "$h" --argjson s "$s" --arg k "$k" --arg rev "$repo_rev" \
     --arg ts "$(iso)" --arg run "${GITHUB_RUN_ID:-local}" \
     '.seq = ((.seq // 0) + 1) | .updated_at = $ts | .blobs[$n] = {sha256:$h,size:$s,kind:$k,updated_at:$ts,node_run:$run,repo_rev:$rev}' \
     "$idx" >"$tmp" && mv "$tmp" "$idx"
  mem_sign "$idx"
}

# mem_reindex_from_disk — regenerate every index entry from the blob files that
# are on disk.  manifest/blobs.json is derived data: two nodes (or a node and
# the watchdog workflow) can both rewrite it, and a rebase then conflicts on a
# file nobody edits by hand.  Rebuilding from blobs/ *is* the union merge.
mem_reindex_from_disk() {
  local f label
  mkdir -p "$MEM_DIR/blobs"
  local found=0
  for f in "$MEM_DIR"/blobs/*.tar.zst.age; do
    [ -e "$f" ] || continue
    label="$(basename "$f" .tar.zst.age)"
    mem_index_put "$label" "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")" >/dev/null || return 1
    found=$((found+1))
  done
  [ "$found" -gt 0 ]
}

# mem_put_blob <label> <path...>   — tar+zstd+age, then index+sign
mem_put_blob() {
  local label="$1"; shift
  local name="${label}.tar.zst.age" tmp sha size age_bin
  [ -n "${AGE_IDENTITY_FILE:-}" ] || die "AGE_IDENTITY_FILE not set"
  age_bin="$(command -v age || echo /usr/local/bin/age)"
  [ -x "$age_bin" ] || die "age binary not found"
  local recipient=""
  # 1) the recipient published in the repository (public, verified by prepare.sh)
  if [ -s "$REPO_DIR/manifest/trust/memory_recipient.txt" ]; then
    recipient="$(tr -d '[:space:]' <"$REPO_DIR/manifest/trust/memory_recipient.txt")"
  fi
  # 2) fall back to deriving it from the private identity
  if [ -z "$recipient" ] && command -v age-keygen >/dev/null 2>&1; then
    recipient="$(age-keygen -y "$AGE_IDENTITY_FILE" 2>/dev/null | tr -d '\n' || true)"
  fi
  [ -n "$recipient" ] || die "cannot determine the age recipient (no trust file, no age-keygen)"
  tmp="$(mktemp -d)"
  local tarfile="$tmp/${label}.tar.zst"
  tar -C / -cf - "$@" 2>/dev/null | zstd -q -3 -o "$tarfile" - || { warn "tar/zstd failed for $label"; rm -rf "$tmp"; return 1; }
  mkdir -p "$MEM_DIR/blobs"
  "$age_bin" -r "$recipient" -o "$MEM_DIR/blobs/$name" "$tarfile" || { rm -rf "$tmp"; return 1; }
  chmod 644 "$MEM_DIR/blobs/$name"
  sha="$(sha256sum "$MEM_DIR/blobs/$name" | cut -d' ' -f1)"
  size="$(stat -c%s "$MEM_DIR/blobs/$name")"
  mem_index_put "${label}" "$sha" "$size"
  rm -rf "$tmp"
  printf '%s' "$name"
}

mem_get_blob() { # mem_get_blob <label> <destdir>  — verify hash from signed index, decrypt, extract
  local label="$1" dest="$2" name="${1}.tar.zst.age" f want got tmp
  f="$MEM_DIR/blobs/$name"
  [ -f "$f" ] || { warn "blob missing: $name"; return 1; }
  want="$(mem_index_get "$label")"
  if [ -n "$want" ]; then
    got="$(sha256sum "$f" | cut -d' ' -f1)"
    [ "$want" = "$got" ] || { warn "blob hash mismatch for $label (index=$want got=$got) — refusing"; return 1; }
  else
    warn "no signed index entry for $label — accepting encrypted blob on AEAD integrity only"
  fi
  tmp="$(mktemp -d)"
  "$(command -v age || echo /usr/local/bin/age)" -d -i "$AGE_IDENTITY_FILE" -o "$tmp/payload.tar.zst" "$f" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  zstd -dq -o "$tmp/payload.tar" "$tmp/payload.tar.zst" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$dest"
  tar -C "$dest" -xf "$tmp/payload.tar" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  return 0
}

mem_blob_exists() { [ -f "$MEM_DIR/blobs/${1}.tar.zst.age" ]; }

# ------------------------------------------------------------- state --------
mem_write_state() { # mem_write_state <basename> <json-file>  (signs + pushes)
  local base="$1" src="$2"
  mkdir -p "$MEM_DIR/state"
  cp "$src" "$MEM_DIR/state/$base"
  mem_sign "$MEM_DIR/state/$base" || true
  mem_commit_push "state(${NODE_HOSTNAME:-node}): update ${base} [run ${GITHUB_RUN_ID:-local}]" state
}

mem_read_state() { # mem_read_state <basename>  -> stdout (unsigned reads allowed, callers verify)
  local base="$1"
  [ -f "$MEM_DIR/state/$base" ] || return 1
  cat "$MEM_DIR/state/$base"
}

mem_state_verified() { # mem_state_verified <basename> -> 0 if signature valid
  mem_verify "$MEM_DIR/state/$1" "$REPO_DIR/manifest/trust/allowed_signers"
}

mem_append_jsonl() { # mem_append_jsonl <basename> <json-line> [max_lines]
  local base="$1" line="$2" max="${3:-400}" f="$MEM_DIR/state/$1"
  mkdir -p "$MEM_DIR/state"
  printf '%s\n' "$line" >>"$f"
  if [ "$(wc -l <"$f")" -gt "$max" ]; then tail -n "$max" "$f" >"$f.tmp" && mv "$f.tmp" "$f"; fi
}
