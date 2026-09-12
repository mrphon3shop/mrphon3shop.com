#!/usr/bin/env bash
# ============================================================================
#  tests/check_memrepo.sh — two writers, one memory repository
#
#  The node's state sync and the watchdog workflow both commit to the memory
#  repository, and both rewrite manifest/blobs.json.  A push that loses that
#  race must not lose data, and must not fail forever either.
#
#  This test lets the *other* writer win the race first, then checks that our
#  store still lands, that the index afterwards describes every blob on the
#  branch (the union of both writers), and that the other writer's commit was
#  not thrown away.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HERE/.." && pwd)"
SECRETS="${SECRETS:-${HOME}/.secrets}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/memrepo-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export INSTALL_ROOT="$WORK/root"
export WORK="$WORK/root/work"
export MEM_DIR="$WORK/mem"
export NODE_STATE="$WORK/root/state" LOG_DIR="$WORK/root/logs" RUN_DIR="$WORK/root/run"
export NODE_HOSTNAME=test-node MEMORY_OWNER=test MEMORY_REPO=memory
export MEMORY_PAT="" MEMORY_BRANCH=main GITHUB_RUN_ID=test-run
export REPO_DIR AGE_IDENTITY_FILE="$SECRETS/age.key"
FLEET_SIGN_KEY="$(cat "$SECRETS/fleet_sign" 2>/dev/null || true)"; export FLEET_SIGN_KEY
export PATH="/usr/local/bin:${PATH}"          # age / age-keygen
[ -s "$AGE_IDENTITY_FILE" ] || { echo "missing $AGE_IDENTITY_FILE"; exit 2; }
[ -n "$FLEET_SIGN_KEY" ]    || { echo "missing $SECRETS/fleet_sign"; exit 2; }

# shellcheck disable=SC1091
. "$REPO_DIR/scripts/lib/common.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/scripts/lib/memrepo.sh"

PASS=0; FAIL=0
ok()  { printf '\033[32m  PASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '\033[31m  FAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
GITC="git -c user.email=t@local -c user.name=tester"

echo "check_memrepo — workspace $WORK"

# 1. a memory repository with an empty blob index, cloned as the node's copy
git init -q --bare --initial-branch=main "$WORK/remote.git"
git clone -q "$WORK/remote.git" "$WORK/seed"
mkdir -p "$WORK/seed/manifest"
printf '{"seq":0,"blobs":{}}\n' > "$WORK/seed/manifest/blobs.json"
printf 'memory repository\n'    > "$WORK/seed/README.md"
$GITC -C "$WORK/seed" add -A >/dev/null && $GITC -C "$WORK/seed" commit -q -m seed
git -C "$WORK/seed" push -q origin main
git clone -q "$WORK/remote.git" "$MEM_DIR"
git -C "$MEM_DIR" config user.email test@local
git -C "$MEM_DIR" config user.name  test
[ -f "$MEM_DIR/manifest/blobs.json" ] && ok "memory repository ready" || bad "memory repository not ready"

# 2. the other writer (the watchdog workflow) commits first, touching the index
git clone -q "$WORK/remote.git" "$WORK/other"
mkdir -p "$WORK/other/state"
printf '{"alive":true,"writer":"watchdog"}\n' > "$WORK/other/state/watchdog_status.json"
jq --arg ts "$(iso)" '.seq = ((.seq // 0) + 1) | .updated_at = $ts
   | .blobs["watchdog-status"] = {sha256:"deadbeef",size:17,kind:"data"}' \
   "$WORK/other/manifest/blobs.json" > "$WORK/other/manifest/blobs.json.new" \
  && mv "$WORK/other/manifest/blobs.json.new" "$WORK/other/manifest/blobs.json"
$GITC -C "$WORK/other" add -A >/dev/null && $GITC -C "$WORK/other" commit -q -m "watchdog: heartbeat"
git -C "$WORK/other" push -q origin main && ok "other writer published first" \
  || bad "other writer could not publish"

# 3. our node stores a blob and pushes — the first push must lose the race
mkdir -p "$WORK/payload"
printf 'hello from the node\n' > "$WORK/payload/file.txt"
rel="$(realpath --relative-to=/ "$WORK/payload/file.txt")"
mem_put_blob demo-blob "$rel" >/dev/null 2>&1 && ok "blob stored locally" || bad "mem_put_blob failed"
mem_commit_push "test: store demo-blob" >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && ok "push landed after the concurrent write" \
              || bad "push failed (rc=$rc) — a losing writer must recover"

# 4. what does a fresh reader see?
git clone -q "$WORK/remote.git" "$WORK/reader"
[ -f "$WORK/reader/blobs/demo-blob.tar.zst.age" ] && ok "our blob is on the branch" \
  || bad "our blob is missing"
[ -f "$WORK/reader/state/watchdog_status.json" ] && ok "the other writer's commit survived" \
  || bad "the other writer's commit was lost"
jq -e '.blobs["demo-blob"]' "$WORK/reader/manifest/blobs.json" >/dev/null 2>&1 \
  && ok "our blob is in the index" || bad "our blob is missing from the index"
jq -e '.blobs["watchdog-status"]' "$WORK/reader/manifest/blobs.json" >/dev/null 2>&1 \
  && ok "the other writer's entry is still in the index" || bad "index lost the other writer's entry"
want="$(jq -r '.blobs["demo-blob"].sha256' "$WORK/reader/manifest/blobs.json")"
got="$(sha256sum "$WORK/reader/blobs/demo-blob.tar.zst.age" | cut -d' ' -f1)"
[ "$want" = "$got" ] && ok "index hash matches the blob" || bad "index hash mismatch"
if command -v ssh-keygen >/dev/null && [ -f "$WORK/reader/manifest/blobs.json.sig" ]; then
  ssh-keygen -Y verify -q -f "$REPO_DIR/manifest/trust/allowed_signers" -I fleet \
    -n "$MEM_SIG_NS" -s "$WORK/reader/manifest/blobs.json.sig" \
    < "$WORK/reader/manifest/blobs.json" >/dev/null 2>&1 \
    && ok "index signature verifies" || bad "index signature does not verify"
fi

echo "result: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
