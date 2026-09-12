#!/usr/bin/env python3
"""Node dashboard (tailnet-only). Reads the node state files and renders a
single self-contained page — no external assets, no network calls."""
from __future__ import annotations

import html
import json
import os
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PANEL_PORT", "8088"))
STATE = os.environ.get("NODE_STATE_DIR", "/opt/mrphon3shop/state")
RUN_DIR = "/opt/mrphon3shop/run"


def load(name: str, default=None):
    try:
        with open(os.path.join(STATE, name), encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:  # noqa: BLE001
        return default if default is not None else {}


def load_run(name: str):
    try:
        with open(os.path.join(RUN_DIR, name), encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:  # noqa: BLE001
        return {}


def tail(path: str, lines: int = 40) -> str:
    try:
        out = subprocess.run(["tail", "-n", str(lines), path], capture_output=True, text=True, timeout=5)
        return out.stdout
    except Exception:  # noqa: BLE001
        return ""


def badge(text: str, ok: bool) -> str:
    color = "#0f9d58" if ok else "#d93025"
    return f'<span style="background:{color};color:#fff;padding:2px 8px;border-radius:10px;font-size:12px">{html.escape(text)}</span>'


def page() -> str:
    meta = load("meta.json")
    hb = load("heartbeat.json")
    funnel = load("funnel.json")
    svc = load("services.json")
    inv = load("inventory.json")
    lease = load("lease.local.json")
    wd = load_run("watchdog.json")

    now = int(time.time())
    deadline = int(hb.get("deadline_epoch") or meta.get("deadline_epoch") or 0)
    left = max(0, deadline - now) if deadline else 0
    up = int(hb.get("uptime_seconds") or 0)

    rows = []
    svc_list = svc.get("services", []) if isinstance(svc, dict) else []
    for s in svc_list:
        rows.append(
            f"<tr><td>{html.escape(str(s.get('name')))}</td><td>{badge(str(s.get('state')), s.get('state')=='healthy')}</td>"
            f"<td>{s.get('port')}</td><td>{html.escape(', '.join(s.get('data_paths') or []) or '—')}</td></tr>")

    pkgs = inv.get("packages", []) if isinstance(inv, dict) else []
    drift = inv.get("drift", []) if isinstance(inv, dict) else []
    pkg_rows = "".join(
        f"<tr><td>{html.escape(str(p.get('kind')))}</td><td>{html.escape(str(p.get('name')))}</td>"
        f"<td>{html.escape(str(p.get('installed') or '—'))}</td><td>{html.escape(str(p.get('status')))}</td></tr>"
        for p in pkgs[:80])

    ssh_cmd = (funnel.get("funnel", {}) or {}).get("ssh_command") or "funnel inactive"

    def kv(label, value):
        return f'<div style="margin:4px 0"><strong>{html.escape(label)}:</strong> <code>{html.escape(str(value))}</code></div>'

    body = f"""<!doctype html><html><head><meta charset="utf-8"><title>mrphon3shop node</title>
<style>
 body{{font:14px/1.5 system-ui,Segoe UI,Roboto,sans-serif;background:#0f1115;color:#e6e6e6;margin:0;padding:24px}}
 h1{{font-size:20px;margin:0 0 4px}} h2{{font-size:15px;margin:24px 0 8px;color:#9ad}}
 .card{{background:#171a21;border:1px solid #232833;border-radius:10px;padding:16px;margin:12px 0}}
 table{{width:100%;border-collapse:collapse}} td,th{{text-align:left;padding:6px 8px;border-bottom:1px solid #232833}}
 code{{background:#0d1017;padding:1px 6px;border-radius:6px}}
 pre{{background:#0d1017;padding:12px;border-radius:8px;overflow:auto;max-height:320px}}
 .muted{{color:#8b93a1;font-size:12px}}
</style></head><body>
<h1>mrphon3shop node — {html.escape(str(meta.get('node','?')))}</h1>
<div class="muted">ephemeral GitHub-hosted runner, chained by a watchdog · data restored from the encrypted memory repository</div>

<div class="card">
 {kv('run id', hb.get('run_id') or meta.get('run_id'))}
 {kv('role', hb.get('role'))}
 {kv('status', hb.get('status'))}
 {kv('uptime', f'{up//60} min')}
 {kv('deadline in', f'{left//60} min')}
 {kv('watchdog phase', wd.get('phase'))}
 {kv('successor run', wd.get('successor'))}
 {kv('public ssh', ssh_cmd)}
 {kv('tailnet ip', funnel.get('tailnet_ip'))}
 {kv('os / kernel', f"{meta.get('os')} / {meta.get('kernel')}")}
</div>

<div class="card">
 <h2>lease</h2>
 {kv('holder', lease.get('holder', {}).get('run_id'))}
 {kv('state', lease.get('state'))}
 {kv('expires', lease.get('expires_at'))}
 {kv('signature trust', lease.get('signature_trust'))}
</div>

<div class="card"><h2>services</h2>
 <table><tr><th>name</th><th>state</th><th>port</th><th>data (persisted)</th></tr>{''.join(rows)}</table>
</div>

<div class="card"><h2>packages ({len(pkgs)} installed, {len(drift)} drift)</h2>
 <table><tr><th>kind</th><th>name</th><th>installed</th><th>status</th></tr>{pkg_rows}</table>
</div>

<div class="card"><h2>watchdog log</h2><pre>{html.escape(tail('/opt/mrphon3shop/logs/watchdog.log', 40))}</pre></div>
<div class="muted">generated {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}</div>
</body></html>"""
    return body


class Handler(BaseHTTPRequestHandler):
    server_version = "mrphon3shop-panel"

    def do_GET(self):  # noqa: N802
        if self.path.rstrip("/") in ("/healthz", "/panel/healthz"):
            self._send(200, "application/json", b'{"status":"ok"}')
            return
        if self.path.rstrip("/") in ("", "/", "/panel"):
            self._send(200, "text/html; charset=utf-8", page().encode())
            return
        self._send(404, "text/plain", b"not found")

    def _send(self, code: int, ctype: str, payload: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):  # quieter logs
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
