#!/usr/bin/env python3
"""
watchdog.py — keeps the chain alive.

Runs inside the serving runner. Two jobs:

  1. housekeeping: heartbeat + encrypted state snapshot on a timer
  2. handover: shortly before this runner's hard deadline it dispatches the
     successor workflow, waits until the successor reports "ready", hands the
     lease over, releases the Tailscale name so the successor can claim it, and
     keeps serving until the successor confirms it is live.

No long sleeps: the loop is event driven with a 5 s tick and adaptive intervals.
Standard library only (the node has no Python dependencies by design).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

# ---------------------------------------------------------------- config ----
def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)

INSTALL_ROOT = env("INSTALL_ROOT", "/opt/mrphon3shop")
STATE_DIR = f"{INSTALL_ROOT}/state"
RUN_DIR = f"{INSTALL_ROOT}/run"
LOG_DIR = f"{INSTALL_ROOT}/logs"
WATCHDOG_LOG = f"{LOG_DIR}/watchdog.log"
STATUS_FILE = f"{RUN_DIR}/watchdog.json"

REPO_DIR = env("REPO_DIR", "/opt/mrphon3shop/work/repo")
OWNER = env("MAIN_OWNER", "mrphon3shop")
REPO = env("MAIN_REPO", "mrphon3shop.com")
WORKFLOW = env("NODE_WORKFLOW", "node.yml")
REF = env("CHAIN_REF", "main")
TOKEN = env("WORKFLOW_PAT", "") or env("GH_PAT", "")

MY_RUN = env("GITHUB_RUN_ID", "local")
MY_URL = env("RUN_URL", "")
NODE = env("NODE_HOSTNAME", "node")

JOB_MAX_MINUTES = int(env("JOB_MAX_MINUTES", "350"))
OVERLAP = int(env("OVERLAP_SECONDS", "300"))
HANDOFF_WAIT = int(env("HANDOFF_WAIT_SECONDS", "420"))
HEARTBEAT_EVERY = int(env("HEARTBEAT_SECONDS", "300"))
SYNC_EVERY = int(env("STATE_SYNC_SECONDS", "1800"))
POLL = 5
MAX_DISPATCHES = int(env("MAX_CHAIN_DISPATCHES", "4"))

STARTED = int(env("JOB_STARTED_EPOCH", str(int(time.time()))))
DEADLINE = STARTED + JOB_MAX_MINUTES * 60

# ---------------------------------------------------------------- helpers ---
def log(msg: str) -> None:
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} [watchdog] {msg}"
    print(line, flush=True)
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(WATCHDOG_LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def sh(args: list[str], timeout: int = 180, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=check)


def secret(text: str) -> str:
    """never let a token reach the log"""
    for value in (TOKEN, env("TS_AUTHKEY"), env("AGE_IDENTITY"), env("MEMORY_PAT")):
        if value and len(value) > 8:
            text = text.replace(value, "<redacted>")
    return text


def write_status(**kw) -> None:
    payload = {"run_id": MY_RUN, "node": NODE, "updated_at": int(time.time()),
               "deadline": DEADLINE, "pid": os.getpid(), **kw}
    try:
        os.makedirs(RUN_DIR, exist_ok=True)
        tmp = STATUS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        os.replace(tmp, STATUS_FILE)
    except OSError as exc:
        log(f"status write failed: {exc}")


# ---------------------------------------------------------------- github ----
def api(path: str, method: str = "GET", body: dict | None = None) -> dict:
    req = urllib.request.Request(
        f"https://api.github.com{path}", method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Bearer {TOKEN}",
                 "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28",
                 "User-Agent": f"{NODE}-watchdog"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read().decode()
    return json.loads(raw) if raw.strip() else {}


def dispatch_successor(reason: str) -> int | None:
    if not TOKEN:
        log("FATAL: no workflow token — cannot spawn the successor")
        return None
    try:
        api(f"/repos/{OWNER}/{REPO}/actions/workflows/{WORKFLOW}/dispatches", "POST",
            {"ref": REF, "inputs": {"reason": reason, "supersedes": MY_RUN, "successor": "chain"}})
    except urllib.error.HTTPError as exc:
        log(f"dispatch rejected: HTTP {exc.code} {secret(exc.read().decode()[:200])}")
        return None
    except Exception as exc:  # noqa: BLE001
        log(f"dispatch failed: {exc}")
        return None

    # find the run we just created
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            runs = api(f"/repos/{OWNER}/{REPO}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=10")
            for run in runs.get("workflow_runs", []):
                if run.get("head_branch") != REF:
                    continue
                try:
                    created = time.mktime(time.strptime(run["created_at"], "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
                except Exception:  # noqa: BLE001
                    created = 0
                if created > time.time() - 180 and str(run["id"]) != MY_RUN:
                    return int(run["id"])
        except Exception as exc:  # noqa: BLE001
            log(f"run lookup failed: {exc}")
        time.sleep(POLL)
    log("could not identify the dispatched run (it may still be queued)")
    return None


def run_state(run_id: int) -> tuple[str, str]:
    try:
        run = api(f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}")
        return run.get("status", "unknown"), run.get("conclusion") or ""
    except Exception as exc:  # noqa: BLE001
        log(f"run status failed: {exc}")
        return "unknown", ""


# ------------------------------------------------------------- mem repo -----
def mem_pull() -> None:
    try:
        sh(["git", "-C", f"{INSTALL_ROOT}/work/mem", "pull", "--rebase", "--quiet", "origin", "main"], timeout=60)
    except Exception:  # noqa: BLE001
        pass


def mem_json(name: str) -> dict:
    path = f"{INSTALL_ROOT}/work/mem/state/{name}"
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:  # noqa: BLE001
        return {}


def successor_ready(succ_run: int) -> bool:
    mem_pull()
    handoff = mem_json("handoff.json")
    hb = mem_json("heartbeat.json")
    if str(handoff.get("run_id")) == str(succ_run) and handoff.get("ready"):
        return True
    if str(hb.get("run_id")) == str(succ_run):
        return True
    return False


def successor_serving(succ_run: int) -> bool:
    mem_pull()
    hb = mem_json("heartbeat.json")
    return str(hb.get("run_id")) == str(succ_run) and hb.get("role") == "leader" and bool(hb.get("funnel", {}).get("enabled"))


# ---------------------------------------------------------------- actions ---
def do_heartbeat(note: str = "") -> None:
    args = [f"{REPO_DIR}/scripts/60-heartbeat.sh", "beat"]
    if note:
        args.append(note)
    try:
        sh(args, timeout=90)
    except Exception as exc:  # noqa: BLE001
        log(f"heartbeat failed: {exc}")


def do_sync(final: bool = False) -> None:
    args = [f"{REPO_DIR}/scripts/80-state-sync.sh"] + (["--final"] if final else [])
    try:
        res = sh(args, timeout=600)
        log(f"state sync rc={res.returncode}")
        if res.returncode != 0:
            log(secret(res.stderr.strip()[-300:]))
    except Exception as exc:  # noqa: BLE001
        log(f"state sync failed: {exc}")


def funnel_state() -> dict:
    try:
        with open(f"{STATE_DIR}/funnel.json", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:  # noqa: BLE001
        return {}


def repair_funnel(attempt: int) -> None:
    """the public door is the whole point — retry it if it is not published"""
    log(f"funnel is inactive — repair attempt {attempt}")
    try:
        res = sh([f"{REPO_DIR}/scripts/50-tailscale-funnel.sh"], timeout=420)
        state = funnel_state()
        log(f"repair rc={res.returncode} funnel_enabled={state.get('funnel', {}).get('enabled')}")
        if res.returncode != 0:
            log(secret(res.stderr.strip()[-300:]))
    except Exception as exc:  # noqa: BLE001
        log(f"funnel repair failed: {exc}")


OPS_HANDLED = {"requested_at": ""}


def check_ops_request() -> bool:
    """Operator channel: state/ops.json in the memory repo. `handoff: true`
    means 'give the chain to a fresh runner now' — the reboot button."""
    try:
        ops = mem_json("ops.json")
    except Exception:  # noqa: BLE001
        return False
    if not ops or not ops.get("handoff"):
        return False
    stamp = str(ops.get("requested_at", ""))
    if not stamp or stamp == OPS_HANDLED["requested_at"]:
        return False
    OPS_HANDLED["requested_at"] = stamp
    log(f"operator requested an immediate handover ({ops.get('requested_by', 'unknown')}) — rebooting the chain")
    write_status(phase="handoff-requested", requested_at=stamp)
    return True


def tailscale_logout() -> None:
    for cmd in (["sudo", "tailscale", "logout"], ["tailscale", "logout"]):
        try:
            res = sh(cmd, timeout=45)
            if res.returncode == 0:
                log("tailnet identity released (hostname free for the successor)")
                return
        except Exception:  # noqa: BLE001
            continue
    log("WARN: tailscale logout failed — successor will re-register if the name is busy")


def handoff(succ_run: int) -> bool:
    log(f"handing over to run {succ_run}")
    try:
        sh([f"{REPO_DIR}/scripts/70-lease.sh", "handoff", str(succ_run)], timeout=120)
    except Exception as exc:  # noqa: BLE001
        log(f"lease handoff cmd failed: {exc}")
    do_sync(final=True)
    tailscale_logout()

    wait_until = time.time() + HANDOFF_WAIT
    while time.time() < wait_until:
        if successor_serving(succ_run):
            log(f"successor {succ_run} is serving — this node can retire")
            write_status(phase="retired", successor=succ_run)
            return True
        status, conclusion = run_state(succ_run)
        if status == "completed" and conclusion not in ("success", ""):
            log(f"successor {succ_run} finished as {conclusion}")
            return False
        time.sleep(POLL)
    log("successor did not confirm serving within the handoff window")
    return False


def main() -> int:
    log(f"watchdog start: run={MY_RUN} node={NODE} deadline_in={DEADLINE - int(time.time())}s overlap={OVERLAP}s")
    write_status(phase="serving", successor=None)

    next_hb = time.time() + HEARTBEAT_EVERY
    next_sync = time.time() + SYNC_EVERY
    dispatched: int | None = None
    dispatch_attempts = 0
    funnel_repairs = 0
    next_funnel_check = time.time() + 120
    dispatch_at = DEADLINE - OVERLAP
    retired = False
    force_handoff = False
    next_ops_check = time.time() + 60

    while True:
        now = int(time.time())

        if now >= next_hb:
            do_heartbeat()
            next_hb = now + HEARTBEAT_EVERY
        if now >= next_sync and not retired:
            do_sync()
            next_sync = now + SYNC_EVERY
        if now >= next_ops_check and not retired:
            if check_ops_request():
                force_handoff = True
                dispatch_at = min(dispatch_at, now)
            next_ops_check = now + 60
        if now >= next_funnel_check and not retired:
            funnel = funnel_state().get("funnel", {})
            if funnel.get("enabled") and not funnel.get("verified"):
                try:
                    res = sh([f"{REPO_DIR}/scripts/55-funnel-selftest.sh"], timeout=200)
                    if res.returncode == 0:
                        state_path = f"{STATE_DIR}/funnel.json"
                        with open(state_path, encoding="utf-8") as fh:
                            doc = json.load(fh)
                        doc.setdefault("funnel", {})["verified"] = True
                        with open(state_path, "w", encoding="utf-8") as fh:
                            json.dump(doc, fh, indent=2)
                        log("public door verified by the watchdog — state updated")
                        do_sync()
                except Exception as exc:  # noqa: BLE001
                    log(f"door verification attempt failed: {exc}")
            if not funnel.get("enabled"):
                if funnel_repairs < 3:
                    funnel_repairs += 1
                    repair_funnel(funnel_repairs)
                else:
                    log("funnel still inactive after 3 repair attempts — giving up this boot")
                    funnel_repairs = 99
            next_funnel_check = now + 300

        # hard stop: never get killed mid-write
        if now >= DEADLINE + 120:
            log("hard stop reached — final snapshot and exit")
            do_sync(final=True)
            write_status(phase="stopped")
            return 0

        if retired:
            time.sleep(POLL)
            continue

        # start the successor shortly before our deadline
        if (now >= dispatch_at or force_handoff) and dispatch_attempts < MAX_DISPATCHES:
            if dispatched is None:
                log(f"T-{DEADLINE - now}s: dispatching successor")
                dispatched = dispatch_successor("chain")
                dispatch_attempts += 1
                if dispatched:
                    log(f"successor run id: {dispatched}")
                    write_status(phase="handoff-pending", successor=dispatched)
                else:
                    dispatch_at = now + 60
            else:
                status, conclusion = run_state(dispatched)
                if status == "completed" and conclusion not in ("success", ""):
                    log(f"dispatched successor {dispatched} ended ({conclusion}) — retrying")
                    dispatched = None
                    dispatch_at = now + 30
                elif status in ("queued", "in_progress", "waiting", "requested", "pending"):
                    if successor_ready(dispatched):
                        log(f"successor {dispatched} reports ready — starting handoff")
                        if handoff(dispatched):
                            retired = True
                        else:
                            dispatched = None
                            dispatch_at = now + 30
                    else:
                        write_status(phase="successor-booting", successor=dispatched)
                time.sleep(POLL)

        time.sleep(POLL)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
