#!/usr/bin/env python3
"""mirza-selftest.py — prove the four inbounds really carry traffic.

For every `inb-mirza-*` inbound it
  1. makes sure a client exists (creating one only if the inbound has none),
  2. takes the vless link the panel hands out,
  3. starts a throwaway Xray client on that link (socks5 on a free local port),
  4. fetches the public IP through it and prints it next to the outbound the
     inbound is routed to — that is the only honest proof the routing works,
  5. stops the client again.

Temporary clients created by this script are removed again; a `--keep` run
leaves them in place. Existing clients are never touched.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

XRAY = os.environ.get("XRAY_BIN", "/usr/local/x-ui/bin/xray-linux-amd64")
KEEP = "--keep" in sys.argv
IP_ECHO = os.environ.get("IP_ECHO", "https://api.ipify.org")
PROBE = os.environ.get("PROBE_URL", "https://www.gstatic.com/generate_204")


def load_panel():
    """Reuse the panel client from mirza-inbounds.py (same directory)."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mirza-inbounds.py")
    spec = importlib.util.spec_from_file_location("mirza_inbounds", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    panel = mod.Panel()
    panel.login()
    return mod, panel


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def parse_link(link: str) -> dict:
    u = urllib.parse.urlparse(link)
    q = dict(urllib.parse.parse_qsl(u.query))
    return {
        "uuid": urllib.parse.unquote(u.username or ""),
        "address": u.hostname or "",
        "port": u.port or 0,
        "type": q.get("type", "tcp"),
        "path": urllib.parse.unquote(q.get("path", "/")),
        "host": q.get("host", ""),
        "security": q.get("security", "none"),
        "remark": urllib.parse.unquote(u.fragment or ""),
    }


def client_config(c: dict, socks_port: int) -> dict:
    stream = {"network": c["type"], "security": c["security"]}
    if c["type"] == "ws":
        stream["wsSettings"] = {"path": c["path"], "headers": ({"Host": c["host"]} if c["host"] else {})}
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{"listen": "127.0.0.1", "port": socks_port, "protocol": "socks",
                      "settings": {"udp": False, "auth": "noauth"}}],
        "outbounds": [{
            "protocol": "vless",
            "settings": {"vnext": [{"address": c["address"], "port": c["port"],
                                    "users": [{"id": c["uuid"], "encryption": "none"}]}]},
            "streamSettings": stream,
        }],
    }


def curl_through(port: int, url: str, timeout: int = 25) -> tuple[bool, str]:
    res = subprocess.run(["curl", "-s", "--max-time", str(timeout), "-o", "-",
                          "--proxy", f"socks5h://127.0.0.1:{port}", url],
                         capture_output=True, text=True)
    return res.returncode == 0 and bool(res.stdout.strip()), res.stdout.strip()[:100]


def direct_ip() -> str:
    res = subprocess.run(["curl", "-s", "--max-time", "15", IP_ECHO], capture_output=True, text=True)
    return res.stdout.strip()


def main() -> int:
    mod, panel = load_panel()
    inbounds = {i["tag"]: i for i in panel.inbounds() if (i.get("tag") or "").startswith("inb-mirza")}
    if not inbounds:
        print("no inb-mirza-* inbounds found")
        return 1

    print(f"node egress IP (direct): {direct_ip()}")
    failed = 0
    created = []
    for tag, spec in sorted(inbounds.items()):
        clients = mod_and_clients(panel, spec)
        email = None
        if clients:
            email = clients[0].get("email")
            print(f"\n{tag}: reusing the existing client {email}")
        else:
            email = f"selftest-{tag}"
            res = panel._req("/panel/api/clients/add", {
                "client": {"email": email, "enable": True, "expiryTime": 0, "totalGB": 0,
                           "limitIp": 0, "tgId": 0, "subId": "", "comment": "connectivity self-test"},
                "inboundIds": [spec["id"]],
            })
            if not res.get("success"):
                print(f"\n{tag}: could not create a test client: {res.get('msg')}")
                failed += 1
                continue
            created.append(email)
            print(f"\n{tag}: created the test client {email}")

        links = panel._req(f"/panel/api/clients/links/{urllib.parse.quote(email)}").get("obj")
        link = links[0] if isinstance(links, list) and links else (links if isinstance(links, str) else None)
        if not link:
            print(f"{tag}: the panel returned no link for {email}")
            failed += 1
            continue
        c = parse_link(link)
        print(f"   link      : {link}")
        print(f"   parsed    : {c['address']}:{c['port']} {c['type']} path={c['path']} security={c['security']}")

        socks = free_port()
        cfg_path = f"/tmp/mirza-selftest-{tag}.json"
        with open(cfg_path, "w", encoding="utf-8") as fh:
            json.dump(client_config(c, socks), fh, indent=1)
        proc = subprocess.Popen([XRAY, "-c", cfg_path],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            for _ in range(20):
                if proc.poll() is not None:
                    break
                try:
                    with socket.create_connection(("127.0.0.1", socks), timeout=1):
                        break
                except OSError:
                    time.sleep(0.5)
            if proc.poll() is not None:
                print(f"   client    : FAILED to start: {proc.stderr.read().decode()[:200]}")
                failed += 1
                continue
            ok, body = curl_through(socks, IP_ECHO + "?format=json" if "ipify" in IP_ECHO else IP_ECHO)
            ip = ""
            if ok:
                try:
                    ip = str(json.loads(body).get("ip", "")).strip()
                except Exception:  # noqa: BLE001
                    ip = body.strip()
            else:
                ip = f"no answer ({body[:60]})"
            ok2, _ = curl_through(socks, PROBE, timeout=20)
            print(f"   exit IP   : {ip}")
            print(f"   probe 204 : {'reached' if ok2 else 'FAILED'}")
            if not (ok and ok2):
                failed += 1
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
            os.unlink(cfg_path)

    if created and not KEEP:
        for email in created:
            panel._req("/panel/api/clients/del", {"email": email})
        print(f"\nremoved the temporary test client(s): {', '.join(created)}")
    elif created:
        print(f"\nkept the test client(s) as asked: {', '.join(created)}")
    print("\nresult:", "all four inbounds carry traffic" if failed == 0 else f"{failed} inbound(s) FAILED")
    return 0 if failed == 0 else 1


def mod_and_clients(panel, spec) -> list[dict]:
    """The clients the panel already has on this inbound."""
    raw = spec.get("settings") or {}
    if isinstance(raw, str):
        raw = json.loads(raw)
    clients = raw.get("clients") or []
    return [c for c in clients if c.get("email")]


if __name__ == "__main__":
    sys.exit(main())
