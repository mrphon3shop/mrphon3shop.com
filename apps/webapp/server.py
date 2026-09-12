#!/usr/bin/env python3
"""webapp — the demo application.

It exists to prove the promise of this whole system: application data and
configuration survive the death of the runner they were running on. Every time
the process starts it increments a boot counter in its data directory; that
directory is snapshotted (encrypted) into the memory repository and restored on
the next runner. If the counter keeps growing, the storage layer works.
"""
from __future__ import annotations

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("WEBAPP_PORT", "8090"))
DATA = os.environ.get("NODE_DATA_DIR", "/opt/mrphon3shop/data/webapp")
CONF = os.environ.get("WEBAPP_CONFIG", "/opt/mrphon3shop/etc/webapp")
STORE = os.path.join(DATA, "store.json")
CONFIG = os.path.join(CONF, "config.json")


def load() -> dict:
    os.makedirs(DATA, exist_ok=True)
    try:
        with open(STORE, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:  # noqa: BLE001
        return {"boots": 0, "notes": [], "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}


def save(store: dict) -> None:
    tmp = STORE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(store, fh, indent=2)
    os.replace(tmp, STORE)


def config() -> dict:
    os.makedirs(CONF, exist_ok=True)
    if not os.path.exists(CONFIG):
        with open(CONFIG, "w", encoding="utf-8") as fh:
            json.dump({"greeting": "hello from a runner that will not live long",
                       "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, fh, indent=2)
    try:
        with open(CONFIG, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:  # noqa: BLE001
        return {}


class Handler(BaseHTTPRequestHandler):
    server_version = "mrphon3shop-webapp"

    def do_GET(self):  # noqa: N802
        if self.path.rstrip("/") in ("/healthz", "/webapp/healthz"):
            self._json(200, {"status": "ok", "boots": load()["boots"]})
            return
        if self.path.rstrip("/") in ("", "/", "/webapp"):
            store, cfg = load(), config()
            notes = "".join(f"<li>{n['text']} <span class=muted>({n['at']}, run {n.get('run','?')})</span></li>"
                            for n in store.get("notes", [])[-20:])
            html = f"""<!doctype html><html><head><meta charset=utf-8><title>webapp</title>
<style>body{{font:14px/1.6 system-ui,sans-serif;background:#0f1115;color:#e8e8e8;padding:28px}}
code{{background:#0d1017;padding:2px 6px;border-radius:6px}}.muted{{color:#8b93a1;font-size:12px}}
input{{padding:8px;border-radius:6px;border:1px solid #333;background:#0d1017;color:#eee;width:320px}}</style>
</head><body>
<h1>{cfg.get('greeting','hello')}</h1>
<p>boots on this runner lineage: <code>{store.get('boots')}</code></p>
<p>data dir: <code>{DATA}</code> · config dir: <code>{CONF}</code></p>
<form method=POST action="/note"><input name=text placeholder="a note that must survive the runner"><button>save</button></form>
<ul>{notes}</ul>
<div class=muted>this page is served by runner {os.environ.get('NODE_RUN_ID','local')} · store created {store.get('created_at')}</div>
</body></html>"""
            self._send(200, "text/html; charset=utf-8", html.encode())
            return
        if self.path.rstrip("/") == "/notes":
            self._json(200, load())
            return
        self._send(404, "text/plain", b"not found")

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8", "replace")
        store = load()
        text = ""
        if self.path.rstrip("/") == "/note":
            if raw.startswith("text="):
                from urllib.parse import parse_qs, unquote_plus
                text = parse_qs(raw).get("text", [""])[0]
            else:
                try:
                    text = json.loads(raw).get("text", "")
                except Exception:  # noqa: BLE001
                    text = raw[:200]
            if text:
                store.setdefault("notes", []).append(
                    {"text": text[:400], "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                     "run": os.environ.get("NODE_RUN_ID", "local")})
                save(store)
            self.send_response(303)
            self.send_header("Location", "/")
            self.end_headers()
            return
        self._send(404, "text/plain", b"not found")

    def _json(self, code: int, payload: dict) -> None:
        self._send(code, "application/json", json.dumps(payload).encode())

    def _send(self, code: int, ctype: str, payload: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    store = load()
    store["boots"] = int(store.get("boots", 0)) + 1
    store["last_boot"] = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                          "run": os.environ.get("NODE_RUN_ID", "local"),
                          "hostname": os.environ.get("NODE_HOSTNAME", "?")}
    save(store)
    config()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
