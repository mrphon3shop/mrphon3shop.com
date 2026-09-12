#!/usr/bin/env bash
# ============================================================================
#  tests/local-harness.sh — rehearse the whole node lifecycle on this machine
#  with a *local* git repository standing in for the memory repository.
#
#  It exercises: bootstrap, lease, restore, package convergence, services,
#  heartbeat, encrypted state sync, finalize and the smoke tests.
#
#  Usage:  bash tests/local-harness.sh [--full] [--with-packages]
#  Nothing leaves the machine.  Secrets are read from ~/.secrets (age + fleet).
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HERE/.." && pwd)"
RUN="/tmp/harness-$(date -u +%s)"
SECRETS="${SECRETS:-${HOME}/.secrets}"
FULL=0; PKGS=0
for a in "$@"; do
  [ "$a" = "--full" ] && FULL=1
  [ "$a" = "--with-packages" ] && PKGS=1
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
PASS=0; FAIL=0
ok()   { green "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { red   "  FAIL  $*"; FAIL=$((FAIL+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

bold "local harness — workspace $RUN"
mkdir -p "$RUN/work"
export INSTALL_ROOT="/opt/mrphon3shop"   # same layout as a real node
export WORK="$INSTALL_ROOT/work"
export MEM_DIR="$INSTALL_ROOT/work/mem"
export NODE_STATE="$INSTALL_ROOT/state"
export NODE_DATA_DIR="$INSTALL_ROOT/data/webapp"
JOB_STARTED_EPOCH="$(date -u +%s)"; export JOB_STARTED_EPOCH
export GITHUB_RUN_ID="local-$$"
export GITHUB_SHA="local"
export AGE_IDENTITY_FILE="$SECRETS/age.key"
FLEET_SIGN_KEY="$(cat "$SECRETS/fleet_sign" 2>/dev/null || true)"; export FLEET_SIGN_KEY
export MEMORY_OWNER=local MEMORY_REPO=memory MAIN_OWNER=local MAIN_REPO=repo
export MEMORY_PAT=""                     # local remote: no auth needed
export TS_AUTHKEY="dummy-not-used-locally"
export NODE_HOSTNAME=mrphon3shop-node
export TAILNET_DNS=tail3641f4.ts.net
export JOB_MAX_MINUTES=350

[ -s "$AGE_IDENTITY_FILE" ] || { red "missing $AGE_IDENTITY_FILE"; exit 2; }
[ -n "$FLEET_SIGN_KEY" ]    || { red "missing $SECRETS/fleet_sign"; exit 2; }

# ---------------------------------------------------------------------------
bold "1. fake memory repository"
mkdir -p "$RUN/remote.git" && git init -q --bare --initial-branch=main "$RUN/remote.git"
git -C "$REPO_DIR" --work-tree="$RUN/seed" checkout-index -a 2>/dev/null || true   # noop safeguard
cp -a /home/user/repos/mrphon3shop-data/. "$RUN/seed" 2>/dev/null || mkdir -p "$RUN/seed"
git -C "$RUN/seed" init -q
git -C "$RUN/seed" -c user.email=h@l -c user.name=harness add -A
git -C "$RUN/seed" -c user.email=h@l -c user.name=harness commit -q -m "seed memory repository"
git -C "$RUN/seed" branch -M main
git -C "$RUN/seed" remote add origin "$RUN/remote.git" 2>/dev/null || true
git -C "$RUN/seed" push -q origin main
git clone -q "$RUN/remote.git" "$MEM_DIR"
git -C "$MEM_DIR" config user.email harness@local
git -C "$MEM_DIR" config user.name harness
check "memory repository reachable" "git -C '$MEM_DIR' log --oneline -1"

# ---------------------------------------------------------------------------
bold "2. bootstrap"
export REPO_DIR NODE_REPO="$REPO_DIR"
if { sudo -E bash "$REPO_DIR/scripts/10-bootstrap.sh" && { [ -z "${ROOT_PASSWORD:-}" ] || sudo -E bash "$REPO_DIR/scripts/15-passwords.sh"; }; } >"$RUN/bootstrap.log" 2>&1; then ok "bootstrap ran"; else bad "bootstrap failed (see $RUN/bootstrap.log)"; tail -12 "$RUN/bootstrap.log"; fi
check "root authorized_keys installed" "sudo grep -q ssh- /root/.ssh/authorized_keys"
check "sshd key-only"                  "sudo bash '$REPO_DIR/tests/check_sshd.sh'"
check "node-status installed"          "test -x /usr/local/bin/node-status"

# ---------------------------------------------------------------------------
bold "3. lease (leader election)"
if [ "$(sudo -E bash "$REPO_DIR/scripts/70-lease.sh" acquire 2>/dev/null | tail -1)" = "leader" ]; then ok "first node becomes leader"; else bad "lease acquire did not return leader"; fi
check "lease published to memory repo" "jq -e '.state==\"serving\" and .holder.run_id!=\"\"' '$MEM_DIR/state/lease.json'"
if sudo -E bash "$REPO_DIR/scripts/70-lease.sh" status | grep -q '"signature_trust": "ok"'; then ok "lease signature verifies"; else bad "lease signature did not verify"; fi

# ---------------------------------------------------------------------------
bold "4. restore (nothing to restore yet — must still succeed)"
if sudo -E bash "$REPO_DIR/scripts/20-restore.sh" >"$RUN/restore.log" 2>&1; then ok "restore ran"; else bad "restore failed"; tail -8 "$RUN/restore.log"; fi

# ---------------------------------------------------------------------------
if [ "$PKGS" = 1 ]; then
  bold "5. package convergence (this installs apt packages)"
  INSTALL_EXTRA=0 timeout 600 sudo -E bash "$REPO_DIR/scripts/30-install-packages.sh" >"$RUN/packages.log" 2>&1
  rc=$?
  [ $rc -eq 0 ] && ok "package stage finished" || bad "package stage rc=$rc"
  check "inventory written"        "jq -e '.count > 0' '$INSTALL_ROOT/state/inventory.json'"
  check "inventory blob encrypted" "test -s '$MEM_DIR/blobs/inventory.tar.zst.age'"
  check "blob index signed"        "test -s '$MEM_DIR/manifest/blobs.json.sig'"
else
  bold "5. package convergence (skipped — pass --with-packages)"
fi

# ---------------------------------------------------------------------------
bold "6. services"
if sudo -E SKIP_PROGRAMS=$([ "$WITH_PROGRAMS" = 1 ] && echo 0 || echo 1) bash "$REPO_DIR/scripts/40-apply-services.sh" >"$RUN/services.log" 2>&1; then ok "services applied"; else bad "services failed"; tail -10 "$RUN/services.log"; fi
sleep 2
check "panel responds"  "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8088/healthz | grep -q 200"
check "webapp responds" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8090/healthz | grep -q 200"
check "webapp recorded a boot" "curl -s http://127.0.0.1:8090/healthz | jq -e '.boots >= 1'"

# ---------------------------------------------------------------------------
bold "7. heartbeat + encrypted snapshot"
sudo -E bash "$REPO_DIR/scripts/60-heartbeat.sh" start leader >/dev/null 2>&1
check "heartbeat published" "jq -e '.status==\"running\"' '$MEM_DIR/state/heartbeat.json'"
sudo -E bash "$REPO_DIR/scripts/80-state-sync.sh" --final >"$RUN/sync.log" 2>&1; rc=$?
[ $rc -eq 0 ] && ok "state sync finished" || { bad "state sync rc=$rc"; tail -8 "$RUN/sync.log"; }
check "tailscale state blob or warning" "test -s '$MEM_DIR/blobs/tailscale-state.tar.zst.age' || grep -q 'not stored' '$RUN/sync.log'"
if [ "$PKGS" = 1 ]; then
  check "app data blob stored (webapp)" "test -s '$MEM_DIR/blobs/appdata-webapp.tar.zst.age'"
  # real round trip: decrypt the inventory blob back out of the memory repository
  tmpd="$(mktemp -d)"
  if sudo -E bash -c "AGE_IDENTITY_FILE=$AGE_IDENTITY_FILE . '$REPO_DIR/scripts/lib/common.sh'; . '$REPO_DIR/scripts/lib/memrepo.sh'; load_config; mem_get_blob inventory '$tmpd'" >/dev/null 2>&1; then
    if jq -e '.count > 0' "$tmpd/opt/mrphon3shop/state/inventory.json" >/dev/null 2>&1; then ok "encrypted blob round-trip (decrypt + extract)"; else bad "decrypted blob content unexpected"; fi
  else bad "mem_get_blob failed"; fi
  rm -rf "$tmpd"
fi

# ---------------------------------------------------------------------------
bold "8. smoke tests"
if sudo -E bash "$REPO_DIR/tests/smoke.sh" >"$RUN/smoke.log" 2>&1; then
  sed -n 's/^/  /p' "$RUN/smoke.log" | head -20
  ok "smoke suite completed"
else
  bad "smoke suite failed"; tail -20 "$RUN/smoke.log"
fi
[ -s "$INSTALL_ROOT/state/smoke.json" ] && ok "smoke results recorded" || bad "no smoke.json"

# ---------------------------------------------------------------------------
bold "9. handover + finalize"
sudo -E bash "$REPO_DIR/scripts/70-lease.sh" handoff 999999 >/dev/null 2>&1
check "lease marked as handoff" "jq -e '.state==\"handoff\"' '$MEM_DIR/state/lease.json'"
sudo -E bash "$REPO_DIR/scripts/90-finalize.sh" --reason local-harness >"$RUN/finalize.log" 2>&1
check "finalize wrote a report" "test -s '$INSTALL_ROOT/state/finalize.json'"
check "heartbeat marked stopped" "jq -e '.status==\"stopped\"' '$MEM_DIR/state/heartbeat.json'"

bold "10. simulate the next runner in the chain"
git clone -q "$RUN/remote.git" "$RUN/work/mem2"
stale_lease="$(jq -r '.state' "$RUN/work/mem2/state/lease.json")"
[ "$stale_lease" = "handoff" ] && ok "successor sees the handover request in the memory repo" || bad "successor cannot see handover (state=$stale_lease)"

echo
bold "result: ${PASS} passed, ${FAIL} failed"
echo "artifacts: $RUN"
[ "$FAIL" -eq 0 ] || exit 1
