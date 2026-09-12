#!/usr/bin/env bash
# Only keys that the operator published (or explicitly added on a node) may be
# able to log in as root: this node is publicly reachable, so a stray key that
# shipped with the runner image would be a takeover path.
set -uo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/mrphon3shop}"
AUTH=/root/.ssh/authorized_keys
CANON="$REPO_DIR/manifest/trust/authorized_keys"
OPERATOR="$INSTALL_ROOT/etc/ssh/operator_authorized_keys"
[ -s "$AUTH" ] || { echo "no root authorized_keys"; exit 1; }
allowed="$( { cat "$CANON" 2>/dev/null; cat "$OPERATOR" 2>/dev/null; } | grep . | sort -u )"
bad=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  fp="$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
  [ -n "$fp" ] || { echo "unparsable key line: ${line:0:40}…"; bad=$((bad+1)); continue; }
  if grep -qF "$fp" <(printf '%s\n' "$allowed" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}'); then
    continue
  fi
  echo "unexpected key authorised for root: $fp ($(awk '{print $3}' <<<"$line"))"
  bad=$((bad+1))
done < "$AUTH"
[ "$bad" -eq 0 ] || exit 1
echo "root accepts $(grep -c . <(printf '%s\n' "$allowed")) key(s), all published by the operator"
