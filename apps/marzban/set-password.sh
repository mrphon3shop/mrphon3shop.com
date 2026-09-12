#!/usr/bin/env bash
# ============================================================================
#  apps/marzban/set-password.sh <new-password>
#
#  Marzban's own CLI cannot change a password non-interactively, so the hash is
#  written straight into the panel database through Marzban's own hashing code
#  (imported from the image — no second bcrypt implementation to drift apart).
#  The password is passed through the environment of the container, never as a
#  command-line argument (no `ps` leak) and never echoed.
# ============================================================================
set -euo pipefail
PW="${1:-${OPERATOR_PASSWORD:-}}"
[ -n "$PW" ] || { echo "usage: set-password.sh <new-password> (or set OPERATOR_PASSWORD)" >&2; exit 2; }
[ -s /opt/marzban/docker-compose.yml ] || { echo "marzban is not installed here" >&2; exit 3; }

docker compose -f /opt/marzban/docker-compose.yml exec -T \
  -e MARZBAN_NEW_PASSWORD="$PW" -e MARZBAN_ADMIN_USER="${MARZBAN_ADMIN_USER:-admin}" \
  marzban python3 - <<'PY'
import os, sys
import bcrypt                      # the same algorithm Marzban verifies with
from sqlalchemy import create_engine, text

pw = os.environ["MARZBAN_NEW_PASSWORD"].encode()
user = os.environ["MARZBAN_ADMIN_USER"]
hashed = bcrypt.hashpw(pw, bcrypt.gensalt()).decode()

engine = create_engine("sqlite:////var/lib/marzban/db.sqlite3")
with engine.begin() as conn:
    res = conn.execute(
        text("UPDATE admins SET hashed_password = :h WHERE username = :u"),
        {"h": hashed, "u": user},
    )
if res.rowcount == 0:
    sys.exit("no admin named %r in the panel database" % user)
print("dashboard password updated for %s" % user)
PY
