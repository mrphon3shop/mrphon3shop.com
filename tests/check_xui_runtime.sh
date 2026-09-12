#!/usr/bin/env bash
# The "xray failed" class of failure: 3x-ui writes bin/config.json relative to
# its working directory, so a panel started from the wrong place can never
# (re)start xray. Guard the wiring that prevents it, and — when this runs on a
# node — the live state too.
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
UNIT="${XUI_UNIT:-/etc/systemd/system/mrphon3shop-x-ui.service}"
XUI_DIR="${XUI_DIR:-/usr/local/x-ui}"
fail=0
say() { printf '%s\n' "$*"; }

if grep -q '/proc/\$p/cwd' "$REPO_DIR/apps/x-ui/setup.sh"; then
  say "ok   the setup hook checks the panel's working directory"
else
  say "FAIL the setup hook no longer guards the panel's working directory"; fail=1
fi
if grep -q 'systemctl restart mrphon3shop-x-ui.service' "$REPO_DIR/apps/x-ui/setup.sh"; then
  say "ok   a wrongly-started panel is restarted through its unit"
else
  say "FAIL no recovery path for a wrongly-started panel"; fail=1
fi
if grep -q "xray-linux-amd64" "$REPO_DIR/apps/x-ui/setup.sh"; then
  say "ok   the hook reports whether the xray core is running"
else
  say "FAIL the hook does not check the xray core"; fail=1
fi

if [ -s "$UNIT" ]; then
  wd="$(awk -F= '/^WorkingDirectory=/{print $2}' "$UNIT")"
  if [ "$wd" = "$XUI_DIR" ]; then
    say "ok   unit WorkingDirectory=$wd"
  else
    say "FAIL unit WorkingDirectory='$wd' (expected $XUI_DIR)"; fail=1
  fi
  if grep -q "x-ui.service" "$REPO_DIR/scripts/40-apply-services.sh"; then
    say "ok   the service manager is what starts the panel"
  fi
else
  say "skip no unit file here (not a node)"
fi

if pgrep -x x-ui >/dev/null 2>&1; then
  for p in $(pgrep -x x-ui); do
    cwd="$(readlink "/proc/$p/cwd" 2>/dev/null || echo '?')"
    if [ "$cwd" = "$XUI_DIR" ]; then
      say "ok   live panel pid $p runs in $cwd"
    else
      say "FAIL live panel pid $p runs in $cwd — xray restarts will fail"; fail=1
    fi
  done
  if pgrep -f "xray-linux-amd64" >/dev/null 2>&1; then
    say "ok   live xray core is running"
  else
    say "FAIL the panel is up but xray is not running"; fail=1
  fi
else
  say "skip no panel running here"
fi

exit "$fail"
