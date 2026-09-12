#!/usr/bin/env bash
# ============================================================================
#  apps/marzban/ensure-admin.sh [password]
#
#  Makes the dashboard really usable after a handover:
#    1. the .env the container reads carries the operator's credentials
#       (that is the pair Marzban trusts for its first login / import-from-env)
#    2. the sudo admin exists in the database with exactly that password
#
#  Idempotent: safe to run on every boot.
# ============================================================================
set -euo pipefail
PW="${1:-${OPERATOR_PASSWORD:-}}"
USER_NAME="${MARZBAN_ADMIN_USER:-admin}"
ENV_FILE="${MARZBAN_ENV_FILE:-/opt/marzban/.env}"
[ -n "$PW" ] || { echo "ensure-admin: no password available (set OPERATOR_PASSWORD)" >&2; exit 2; }
[ -s "$ENV_FILE" ] || { echo "ensure-admin: $ENV_FILE missing" >&2; exit 3; }

# --- 1. keep the credentials in step inside .env ----------------------------
if ! grep -qE "^SUDO_USERNAME *= *\"?${USER_NAME}\"?$" "$ENV_FILE" 2>/dev/null; then
  sed -i "s|^SUDO_USERNAME *=.*|SUDO_USERNAME = \"${USER_NAME}\"|" "$ENV_FILE"
fi
printf '%s' "$PW" | python3 - "$ENV_FILE" <<'PY'
import sys, pathlib
env = pathlib.Path(sys.argv[1])
pw = sys.stdin.read()
lines = env.read_text().splitlines()
out, done = [], False
for line in lines:
    if line.startswith("SUDO_PASSWORD"):
        out.append(f'SUDO_PASSWORD = "{pw}"'); done = True
    else:
        out.append(line)
if not done:
    out.append(f'SUDO_PASSWORD = "{pw}"')
env.write_text("\n".join(out) + "\n")
PY
chmod 600 "$ENV_FILE"

# --- 2. the admin itself ----------------------------------------------------
bash "$(dirname "$0")/set-password.sh" "$PW"
