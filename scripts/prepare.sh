#!/usr/bin/env bash
# ============================================================================
#  prepare.sh — materialise secrets as files, export runtime env, stage repo.
#  Nothing here is ever echoed: only fingerprints are printed.
# ============================================================================
export LOG_TAG=prepare
. "$(dirname "$0")/lib/common.sh"
load_config

step "runtime env"
: "${GITHUB_RUN_ID:=local}"; export GITHUB_RUN_ID
: "${JOB_STARTED_EPOCH:=$(now)}"; export JOB_STARTED_EPOCH
: "${RUN_URL:=}"; export RUN_URL

require_secret WORKFLOW_PAT AGE_IDENTITY FLEET_SIGN_KEY
# the same PAT is used to push the memory repository
export MEMORY_PAT="${MEMORY_PAT:-$WORKFLOW_PAT}"

# ---- age identity ----------------------------------------------------------
age_src="$RUN_DIR/age.key"
umask 077; printf '%s\n' "$AGE_IDENTITY" >"$age_src"; chmod 600 "$age_src"
export AGE_IDENTITY_FILE="$age_src"
log "age identity: $(mask "$AGE_IDENTITY") -> $age_src"

# ---- fleet signing key -----------------------------------------------------
fsrc="$RUN_DIR/fleet_sign"
printf '%s\n' "$FLEET_SIGN_KEY" >"$fsrc"; chmod 600 "$fsrc"
export FLEET_SIGN_KEY
log "fleet signing key: $(mask "$FLEET_SIGN_KEY")"

# ---- verify that the secrets really are the trusted keys -------------------
# (ssh-keygen ships with the image; age-keygen may not exist until
#  30-install-packages.sh has run, so that half of the check is best effort)
_sign_pub="$(ssh-keygen -y -f "$fsrc" 2>/dev/null | awk '{print $2}')"
if [ -n "$_sign_pub" ]; then
  if grep -q "$_sign_pub" "$REPO_DIR/manifest/trust/allowed_signers"; then
    log "fleet signing key matches manifest/trust/allowed_signers ($(ssh-keygen -lf <(printf 'ssh-ed25519 %s' "$_sign_pub") 2>/dev/null | awk '{print $2}'))"
  else
    die "FLEET_SIGN_KEY does not match manifest/trust/allowed_signers"
  fi
else
  warn "cannot read the fleet signing key — signatures will not be produced"
fi

if [ -f "$REPO_DIR/manifest/trust/memory_recipient.txt" ]; then
  want="$(tr -d ' \n' <"$REPO_DIR/manifest/trust/memory_recipient.txt")"
  if command -v age-keygen >/dev/null 2>&1; then
    have_pub="$(age-keygen -y "$AGE_IDENTITY_FILE" 2>/dev/null || true)"
    [ "$have_pub" = "$want" ] || die "AGE_IDENTITY does not match manifest/trust/memory_recipient.txt"
    log "age identity matches the repository recipient ($want)"
  else
    log "age-keygen not installed yet — identity will be validated by the first decryption"
  fi
fi

# ---- tailscale auth key ----------------------------------------------------
if [ -n "${TS_AUTHKEY:-}" ]; then log "tailscale auth key: $(mask "$TS_AUTHKEY")"; else warn "no TS_AUTHKEY — funnel/SSH will not come up"; fi

# ---- stage the repository at a stable path ---------------------------------
mkdir -p "$INSTALL_ROOT/work" "$INSTALL_ROOT/etc"
rm -rf "$INSTALL_ROOT/work/repo.stage"
cp -a "$REPO_DIR" "$INSTALL_ROOT/work/repo.stage"
rm -rf "$INSTALL_ROOT/work/repo"
mv "$INSTALL_ROOT/work/repo.stage" "$INSTALL_ROOT/work/repo"
export NODE_REPO="$INSTALL_ROOT/work/repo"

# ---- operator env file for interactive use over SSH ------------------------
SEC="/opt/mrphon3shop/etc/node.secrets.env"
umask 077
cat >"$SEC" <<EOF
# root-only. present only while this runner is alive (the disk dies with it).
export NODE_REPO=$NODE_REPO
export AGE_IDENTITY_FILE=$AGE_IDENTITY_FILE
export MEMORY_PAT='${MEMORY_PAT}'
export WORKFLOW_PAT='${WORKFLOW_PAT}'
export TS_AUTHKEY='${TS_AUTHKEY:-}'
export NODE_HOSTNAME='${NODE_HOSTNAME}'
export TAILNET_DNS='${TAILNET_DNS}'
export FUNNEL_PRIMARY_PORT='${FUNNEL_PRIMARY_PORT}'
export GITHUB_RUN_ID='${GITHUB_RUN_ID}'
export REPO_DIR=$NODE_REPO
export FLEET_SIGN_FILE=$fsrc
export TS_API_TOKEN='${TS_API_TOKEN:-}'
EOF
chmod 600 "$SEC"
grep -c . "$SEC" >/dev/null && log "interactive env written to $SEC (0600, root only)"

# ---- export for the remaining steps ---------------------------------------
{
  echo "JOB_STARTED_EPOCH=$JOB_STARTED_EPOCH"
  echo "AGE_IDENTITY_FILE=$AGE_IDENTITY_FILE"
  echo "NODE_REPO=$NODE_REPO"
  echo "REPO_DIR=$NODE_REPO"
  echo "FLEET_SIGN_FILE=$fsrc"
  echo "MEMORY_PAT=$MEMORY_PAT"
  echo "WORKFLOW_PAT=$WORKFLOW_PAT"
  echo "INITIALIZED=1"
} >>"${GITHUB_ENV:-/dev/null}"

log "prepare complete"
