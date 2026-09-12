#!/usr/bin/env bash
# ============================================================================
#  common.sh — shared helpers for every node script.
#  Rules:  * never echo a secret value  * fail fast  * no long blind sleeps
# ============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------- paths -----
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$LIB_DIR/.." && pwd)"          # .../scripts
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"         # repository root
LOG_TAG="${LOG_TAG:-node}"

INSTALL_ROOT="${INSTALL_ROOT:-/opt/mrphon3shop}"
export INSTALL_ROOT
WORK="${WORK:-$INSTALL_ROOT/work}"
MEM_DIR="$WORK/mem"
RUN_DIR="$INSTALL_ROOT/run"
LOG_DIR="$INSTALL_ROOT/logs"
mkdir -p "$WORK" "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- logs ------
_ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { printf '%s [%s] %s\n' "$(_ts)" "$LOG_TAG" "$*" >&2; }
warn() { printf '%s [%s] WARN %s\n' "$(_ts)" "$LOG_TAG" "$*" >&2; }
die()  { printf '%s [%s] FATAL %s\n' "$(_ts)" "$LOG_TAG" "$*" >&2; exit 1; }
step() { printf '\n%s\n%s [%s] == %s\n%s\n' "------------------------------------------------------------" "$(_ts)" "$LOG_TAG" "$*" "------------------------------------------------------------" >&2; }

# safe fingerprint of a secret (never the value itself)
mask() { local v="${1:-}"; if [ -z "$v" ]; then printf '<unset>'; else printf '<%d bytes, sha256:%s>' "${#v}" "$(printf '%s' "$v" | sha256sum | cut -c1-8)"; fi; }

# ---------------------------------------------------------------- errors ----
trap 'code=$?; [ $code -ne 0 ] && warn "aborted at ${BASH_SOURCE[0]}:${LINENO} (exit $code)" || true' ERR

# ---------------------------------------------------------------- helpers ---
have() { command -v "$1" >/dev/null 2>&1; }

# defaults so that a script keeps working even when sudo stripped the environment
JOB_STARTED_EPOCH="${JOB_STARTED_EPOCH:-$(date -u +%s)}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-local}"
export JOB_STARTED_EPOCH GITHUB_RUN_ID
now()  { date -u +%s; }
iso()  { date -u -d "@${1:-$(now)}" +%Y-%m-%dT%H:%M:%SZ; }

require_secret() { # NAME...
  local missing=0 n
  for n in "$@"; do [ -n "${!n:-}" ] || { warn "missing secret: $n"; missing=1; }; done
  [ "$missing" -eq 0 ] || die "required secrets missing: $*"
}

retry() { # retry <attempts> <seconds-between> <cmd...>
  local tries="$1" pause="$2"; shift 2
  local i
  for i in $(seq 1 "$tries"); do
    if "$@"; then return 0; fi
    [ "$i" -eq "$tries" ] && return 1
    warn "attempt $i/$tries failed: $* — retrying in ${pause}s"
    sleep "$pause"
  done
}

wait_port() { # wait_port <host> <port> <timeout_s>  -> polls every 0.25s
  local host="$1" port="$2" limit="${3:-20}" waited=0
  while [ "$(printf '%.0f' "$waited")" -lt "$limit" ]; do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then exec 3>&- 2>/dev/null; return 0; fi
    sleep 0.25; waited=$(awk -v w="$waited" 'BEGIN{print w+0.25}')
  done
  return 1
}

wait_http() { # wait_http <url> <timeout_s> [expected_code]
  local url="$1" limit="${2:-20}" want="${3:-200}" waited=0 code
  while [ "$(printf '%.0f' "$waited")" -lt "$limit" ]; do
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$url" 2>/dev/null || true)
    [ "$code" = "$want" ] && return 0
    sleep 0.5; waited=$(awk -v w="$waited" 'BEGIN{print w+0.5}')
  done
  return 1
}

deadline_epoch() {
  local max_min="${JOB_MAX_MINUTES:-350}"
  local start="${JOB_STARTED_EPOCH:-$(now)}"
  echo $(( start + max_min * 60 ))
}

# ---------------------------------------------------------------- config ----
load_config() {
  local cfg="${1:-$REPO_DIR/config/node.env}"
  [ -f "$cfg" ] || die "config file not found: $cfg"
  set -a; # shellcheck disable=SC1090
  . "$cfg"; set +a
  mkdir -p "${INSTALL_ROOT:-/opt/mrphon3shop}" 2>/dev/null || true
  mkdir -p "${WORK_DIR:-/opt/mrphon3shop/work}" "${DATA_ROOT:-/opt/mrphon3shop/data}" \
           "${CONFIG_ROOT:-/opt/mrphon3shop/etc}" "${LOG_ROOT:-/opt/mrphon3shop/logs}" \
           "${BACKUP_ROOT:-/opt/mrphon3shop/backups}" 2>/dev/null || true
  : "${NODE_HOSTNAME:?NODE_HOSTNAME missing}"; : "${MEMORY_REPO:?MEMORY_REPO missing}"
}

# ---------------------------------------------------------------- json ------ 
# json_write <file> <jq-filter-args...> : atomically write JSON produced by jq -n
json_write() { local f="$1"; shift; local tmp; tmp="$(mktemp)"; jq -n "$@" >"$tmp" && mv "$tmp" "$f"; }

# ---------------------------------------------------------------- runner ----
is_github_runner() { [ "${GITHUB_ACTIONS:-}" = "true" ]; }

run_meta() {
  jq -n --arg run_id "${GITHUB_RUN_ID:-local}" --arg run_url "${RUN_URL:-}" \
        --arg node "${NODE_HOSTNAME:-unknown}" --arg started "$(iso "$(now)")" \
        --arg job "${GITHUB_JOB:-local}" --arg sha "${GITHUB_SHA:-local}" \
        '{run_id:$run_id, run_url:$run_url, hostname:$node, started_at:$started, job:$job, commit:$sha}'
}
