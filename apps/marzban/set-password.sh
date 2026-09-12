#!/usr/bin/env bash
# ============================================================================
#  apps/marzban/set-password.sh [new-password]
#
#  Marzban's own CLI refuses to change a password non-interactively, so the
#  change goes through Marzban's *own* code inside the container (its models and
#  CRUD helpers) — no second bcrypt implementation that could drift apart from
#  the one the panel verifies with.  The admin is created when it is missing.
#
#  The password travels in the container's environment, never as a command-line
#  argument (no `ps` leak) and is never printed.
# ============================================================================
set -euo pipefail
PW="${1:-${OPERATOR_PASSWORD:-}}"
[ -n "$PW" ] || { echo "usage: set-password.sh <new-password> (or set OPERATOR_PASSWORD)" >&2; exit 2; }
[ -s /opt/marzban/docker-compose.yml ] || { echo "marzban is not installed here" >&2; exit 3; }

docker compose -f /opt/marzban/docker-compose.yml exec -T \
  -e MARZBAN_NEW_PASSWORD="$PW" -e MARZBAN_ADMIN_USER="${MARZBAN_ADMIN_USER:-admin}" \
  marzban python3 - <<'PY'
import os
from app.db import Session, crud                      # Marzban's own layer
from app.models.admin import AdminCreate, AdminModify

user = os.environ["MARZBAN_ADMIN_USER"]
pw = os.environ["MARZBAN_NEW_PASSWORD"]

with Session() as db:
    admin = crud.get_admin(db, user)
    if admin is None:
        crud.create_admin(db, AdminCreate(username=user, password=pw, is_sudo=True))
        print(f"admin {user}: created (sudo)")
    else:
        crud.update_admin(db, admin, AdminModify(password=pw, is_sudo=True))
        print(f"admin {user}: password updated")
PY
