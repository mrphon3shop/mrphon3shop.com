#!/usr/bin/env python3
"""hold.py — keeps the job alive, supervises the watchdog, prints a heartbeat
line to the log so the run is visibly alive, and exits cleanly at handover.

Usage: hold.py [--no-watchdog]
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

INSTALL = os.environ.get("INSTALL_ROOT", "/opt/mrphon3shop")
REPO = os.environ.get("REPO_DIR", f"{INSTALL}/work/repo")
STATUS = f"{INSTALL}/run/watchdog.json"
PIDFILE = f"{INSTALL}/run/watchdog.pid"
STATE = f"{INSTALL}/state"

JOB_MAX = int(os.environ.get("JOB_MAX_MINUTES", "350"))
STARTED = int(os.environ.get("JOB_STARTED_EPOCH", str(int(time.time()))))
DEADLINE = STARTED + JOB_MAX * 60
GRACE_END = DEADLINE + 150


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%SZ', time.gmtime())} [hold] {msg}", flush=True)


def read_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:  # noqa: BLE001
        return {}


def start_watchdog() -> subprocess.Popen | None:
    if "--no-watchdog" in sys.argv:
        log("watchdog disabled by flag")
        return None
    env = dict(os.environ)
    env.setdefault("REPO_DIR", REPO)
    log("starting watchdog")
    proc = subprocess.Popen([sys.executable, f"{REPO}/scripts/watchdog.py"], env=env,
                            stdout=None, stderr=None)
    os.makedirs(os.path.dirname(PIDFILE), exist_ok=True)
    with open(PIDFILE, "w", encoding="utf-8") as fh:
        fh.write(str(proc.pid))
    return proc


def main() -> int:
    proc = start_watchdog()
    last_report = 0.0
    while True:
        now = int(time.time())
        wd = read_json(STATUS)
        phase = wd.get("phase", "unknown")
        if proc is not None and proc.poll() is not None:
            log(f"watchdog exited with code {proc.returncode}")
            proc = None
        if phase in ("retired", "stopped"):
            log(f"watchdog phase={phase} — the successor owns the chain, this node can end")
            return 0
        if now >= GRACE_END:
            log("deadline passed — ending the job (the successor or the memory watchdog will take over)")
            return 0
        if time.time() - last_report > 300:
            hb = read_json(f"{STATE}/heartbeat.json")
            inv = read_json(f"{STATE}/inventory.json")
            svc = read_json(f"{STATE}/services.json")
            healthy = len([s for s in svc.get("services", []) if s.get("state") == "healthy"])
            log(f"phase={phase} role={hb.get('role','?')} funnel={(hb.get('funnel') or {}).get('enabled')} "
                f"services_healthy={healthy} apps={inv.get('count', 0)} "
                f"deadline_in={(DEADLINE - now)//60}min")
            last_report = time.time()
        time.sleep(10)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
