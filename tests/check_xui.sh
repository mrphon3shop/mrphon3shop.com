#!/usr/bin/env bash
# Assert the 3x-ui panel is actually usable:
#   * it answers on its loopback port
#   * the credentials we generated (stored in /etc/x-ui, carried encrypted by the
#     memory repository) really log in
#   * the default admin/admin credential is gone
# No secret is ever printed.
set -uo pipefail
PORT="${XUI_PORT:-2087}"
CREDS=/etc/x-ui/operator-credentials.json
[ -s "$CREDS" ] || { echo "no generated credentials at $CREDS"; exit 1; }

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$PORT/" || true)"
[ "$code" = "200" ] || { echo "panel does not answer on 127.0.0.1:$PORT (http=$code)"; exit 1; }

show="$(sudo /usr/local/x-ui/x-ui setting -show 2>/dev/null)"
if grep -q 'hasDefaultCredential: true' <<<"$show"; then
  echo "panel still uses the default credential"; exit 1
fi

# The panel is a single page app: it hands out a CSRF token that must ride along
# on the login POST.  Retry a few times so a panel that is still warming up
# right after start does not look like a bad password (< 10 s worst case).
login() {
  jar="$(mktemp)"; trap 'rm -f "$jar"' RETURN
  curl -s -c "$jar" -o /dev/null --max-time 6 "http://127.0.0.1:$PORT/" || true
  tok="$(curl -s -b "$jar" -c "$jar" --max-time 6 "http://127.0.0.1:$PORT/csrf-token" | jq -r '.obj // empty')"
  [ -n "$tok" ] || { echo "the panel did not hand out a CSRF token"; return 1; }
  body="$(jq -nc --arg u "$(sudo jq -r .username "$CREDS")" --arg p "$(sudo jq -r .password "$CREDS")" \
          '{username:$u,password:$p}')"
  out="$(curl -s -b "$jar" --max-time 10 -X POST "http://127.0.0.1:$PORT/login" \
          -H 'Content-Type: application/json' -H "X-CSRF-Token: $tok" --data "$body")"
  grep -q '"success":true' <<<"$out"
}
for attempt in 1 2 3 4 5; do
  login && break
  [ "$attempt" = 5 ] && { echo "the operator credentials do not log in: $(jq -r '.msg // .obj.msg // "no message"' <<<"$out" 2>/dev/null)"; exit 1; }
  sleep 2
done

# the panel database must be inside the persisted data path, otherwise the whole
# panel would vanish at the next handover
grep -q '/etc/x-ui' <<<"$(jq -c '.services[]?|select(.name=="x-ui")|.data_paths' /opt/mrphon3shop/state/services.json)" \
  || { echo "x-ui has no persisted data path"; exit 1; }

echo "panel healthy on 127.0.0.1:$PORT, operator login verified, /etc/x-ui persisted"
