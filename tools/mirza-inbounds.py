#!/usr/bin/env python3
"""mirza-inbounds.py — create the tested 3x-ui set through the panel's own API.

Adds (never edits, never deletes):
  * four VLESS/ws inbounds on 127.0.0.1, tags inb-mirza-*, ports 24444-24447
    (or the first four consecutive free ports if those are taken)
  * four SOCKS outbounds (country-khodam-*) next to the panel's default
    `direct` and `blackhole` ones
  * the four routing rules that bind each inbound to its outbound

Run it on the node:  sudo python3 tools/mirza-inbounds.py [--report]
It is idempotent — anything that already exists is left untouched.
"""
from __future__ import annotations

import http.cookiejar
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

BASE = os.environ.get("XUI_BASE", "http://127.0.0.1:2087")
CREDS = os.environ.get("XUI_CREDS", "/etc/x-ui/operator-credentials.json")
PW_FILE = os.environ.get("OPERATOR_PW_FILE", "/root/.opw")
BRAND = os.environ.get("BRAND", "MrPhon")
PREFERRED_PORTS = [24444, 24445, 24446, 24447]

INBOUNDS = [
    {"tag": "inb-mirza-direct", "remark": "{BRAND} USA Direct",
     "path": "/dir-vless", "outbound": "direct"},
    {"tag": "inb-mirza-us", "remark": "{BRAND} USA Proxy 45.32 SOCKS5",
     "path": "/us-vless", "outbound": "country-khodam-us-proxy-02"},
    {"tag": "inb-mirza-fi1", "remark": "{BRAND} Finland Helsinki SOCKS5",
     "path": "/fi1-vless", "outbound": "country-khodam-fi-proxy-01"},
    {"tag": "inb-mirza-fi2", "remark": "{BRAND} Finland Backup SOCKS5",
     "path": "/fi2-vless", "outbound": "country-khodam-fi-proxy-03"},
]

OUTBOUNDS = [
    {"tag": "country-khodam-us-proxy-02", "protocol": "socks",
     "settings": {"servers": [{"address": "45.32.160.61", "port": 1088}]}},
    {"tag": "country-khodam-us-proxy-01", "protocol": "socks",
     "settings": {"servers": [{"address": "47.251.30.12", "port": 6000}]}},
    {"tag": "country-khodam-fi-proxy-01", "protocol": "socks",
     "settings": {"servers": [{"address": "83.147.216.208", "port": 1080}]}},
    {"tag": "country-khodam-fi-proxy-03", "protocol": "socks",
     "settings": {"servers": [{"address": "83.147.216.208", "port": 1080}]}},
]

ROUTING_RULES = [
    {"type": "field", "inboundTag": ["inb-mirza-direct"], "outboundTag": "direct"},
    {"type": "field", "inboundTag": ["inb-mirza-us"], "outboundTag": "country-khodam-us-proxy-02"},
    {"type": "field", "inboundTag": ["inb-mirza-fi1"], "outboundTag": "country-khodam-fi-proxy-01"},
    {"type": "field", "inboundTag": ["inb-mirza-fi2"], "outboundTag": "country-khodam-fi-proxy-03"},
]


def log(msg: str) -> None:
    print(msg, flush=True)


class Panel:
    def __init__(self) -> None:
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.csrf = ""

    def _req(self, path: str, data: dict | None = None, method: str | None = None,
             form: bool = False):
        url = f"{BASE}{path}"
        body = None
        headers = {"Accept": "application/json", "User-Agent": "mirza-inbounds/1.0"}
        if data is not None:
            if form:
                # the xray-template endpoint reads its two fields with PostForm
                body = urllib.parse.urlencode(data).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                body = json.dumps(data).encode()
                headers["Content-Type"] = "application/json"
        if self.csrf:
            headers["X-CSRF-Token"] = self.csrf
        req = urllib.request.Request(url, data=body, headers=headers,
                                     method=method or ("POST" if data is not None else "GET"))
        with self.opener.open(req, timeout=30) as resp:
            raw = resp.read().decode()
        return json.loads(raw) if raw.strip() else {}

    def login(self) -> None:
        page = self.opener.open(f"{BASE}/", timeout=30).read().decode()
        m = re.search(r'name="csrf-token" content="([^"]+)"', page)
        self.csrf = m.group(1) if m else ""
        creds = json.load(open(CREDS))
        pw = os.environ.get("OPERATOR_PASSWORD") or open(PW_FILE).read().strip()
        out = self._req("/login", {"username": creds["username"], "password": pw})
        if not self._req("/panel/api/server/status").get("success", False):
            raise SystemExit("login failed (the API did not accept the session)")

    # ---- api wrappers ----
    def inbounds(self) -> list[dict]:
        return self._req("/panel/api/inbounds/list").get("obj") or []

    def template(self) -> dict:
        """The Xray config the panel will run.

        Priority: the template saved in the panel database (what an operator
        edited last) -> the panel's own default config. The database is read
        directly because the panel's settings API does not always expose the
        template, and this script must never guess.
        """
        cfg = None
        try:
            out = subprocess.run(
                ["sqlite3", "/etc/x-ui/x-ui.db",
                 "select value from settings where key='xrayTemplateConfig'"],
                capture_output=True, text=True, timeout=30).stdout.strip()
            if out:
                cfg = json.loads(out)
        except Exception:  # noqa: BLE001
            cfg = None
        if not cfg:
            obj = self._req("/panel/api/setting/getDefaultJsonConfig").get("obj")
            cfg = obj if isinstance(obj, dict) else json.loads(obj or "{}")
            log("   (the panel has no saved template yet — starting from its built-in default)")
        self.test_url = ""
        try:
            self.test_url = (self._req("/panel/api/setting/all", {}).get("obj") or {}).get("outboundTestUrl") or ""
        except Exception:  # noqa: BLE001
            self.test_url = ""
        if not cfg.get("outbounds"):
            raise SystemExit("could not read the Xray template from the panel")
        return cfg

    def inbound_add(self, payload: dict):
        return self._req("/panel/api/inbounds/add", payload)

    def template_save(self, cfg: dict):
        return self._req("/panel/api/xray/update",
                         {"xraySetting": json.dumps(cfg, indent=2), "outboundTestUrl": self.test_url},
                         form=True)


def listening_ports() -> set[int]:
    out = subprocess.run(["ss", "-ltnH"], capture_output=True, text=True).stdout
    ports = set()
    for line in out.splitlines():
        cols = line.split()
        if len(cols) < 4:
            continue
        for token in (cols[3], cols[4] if len(cols) > 4 else ""):
            m = re.search(r":(\d+)$", token or "")
            if m:
                ports.add(int(m.group(1)))
    return ports


def pick_ports(taken: set[int]) -> tuple[list[int], bool]:
    """The four tested ports when they are free, otherwise the first four
    consecutive free ports above them."""
    if not any(p in taken for p in PREFERRED_PORTS):
        return PREFERRED_PORTS, True
    start = PREFERRED_PORTS[0]
    for base in range(start, 65000 - 4):
        if all(p not in taken for p in range(base, base + 4)):
            return list(range(base, base + 4)), False
    raise SystemExit("no four consecutive free ports found")


def main() -> int:
    panel = Panel()
    panel.login()
    report = "--report" in sys.argv

    existing = panel.inbounds()
    by_tag = {i.get("tag"): i for i in existing if i.get("tag")}
    taken = listening_ports() | {int(i["port"]) for i in existing if i.get("port")}
    # our own inbounds already listening must not count as conflict
    taken -= {int(i["port"]) for i in existing if int(i.get("port") or 0) in PREFERRED_PORTS and i.get("tag", "").startswith("inb-mirza")}
    ports, used_preferred = pick_ports(taken)

    log("== inbounds ==")
    for spec, port in zip(INBOUNDS, ports):
        if spec["tag"] in by_tag:
            log(f"   {spec['tag']:<18} already present on port {by_tag[spec['tag']]['port']} — untouched")
            continue
        payload = {
            "enable": True,
            "remark": spec["remark"].format(BRAND=BRAND),
            "listen": "127.0.0.1",
            "port": port,
            "protocol": "vless",
            "tag": spec["tag"],
            "expiryTime": 0,
            "total": 0,
            "up": 0,
            "down": 0,
            "settings": {"clients": [], "decryption": "none", "fallbacks": []},
            "streamSettings": {"network": "ws", "security": "none",
                               "wsSettings": {"acceptProxyProtocol": False,
                                              "path": spec["path"], "host": "", "headers": {}}},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"],
                         "metadataOnly": False, "routeOnly": False},
        }
        res = panel.inbound_add(payload)
        state = "created" if res.get("success") else f"FAILED: {res.get('msg')}"
        log(f"   {spec['tag']:<18} port {port} path {spec['path']:<12} -> {state}")

    log("== xray template: outbounds + routing ==")
    cfg = panel.template()
    have_out = {o.get("tag") for o in cfg.get("outbounds", [])}
    added_out = [o for o in OUTBOUNDS if o["tag"] not in have_out]
    if added_out:
        cfg.setdefault("outbounds", []).extend(added_out)
        log("   added outbounds: " + ", ".join(o["tag"] for o in added_out))
    else:
        log("   all four SOCKS outbounds already present — untouched")

    routing = cfg.setdefault("routing", {})
    routing.setdefault("domainStrategy", "AsIs")
    rules = routing.setdefault("rules", [])
    have_rules = {tuple(r.get("inboundTag") or []) for r in rules}
    new_rules = [r for r in ROUTING_RULES if tuple(r["inboundTag"]) not in have_rules]
    if new_rules:
        pos = 1 if rules and rules[0].get("inboundTag") == ["api"] else 0
        rules[pos:pos] = new_rules
        log(f"   inserted {len(new_rules)} routing rule(s) after the api rule")
    else:
        log("   routing rules already present — untouched")

    if added_out or new_rules:
        res = panel.template_save(cfg)
        log(f"   template saved: {res.get('success')} {res.get('msg') or ''}".rstrip())
    else:
        log("   template unchanged, nothing to save")

    # ---- verification -------------------------------------------------------
    log("== verification ==")
    now = {i.get("tag"): i for i in panel.inbounds() if i.get("tag")}
    ok = True
    for spec, port in zip(INBOUNDS, ports):
        i = now.get(spec["tag"])
        if not i:
            log(f"   MISSING inbound {spec['tag']}"); ok = False; continue
        st = i.get("streamSettings") or {}
        st = json.loads(st) if isinstance(st, str) else st
        got_path = (st.get("wsSettings") or {}).get("path")
        good = (int(i["port"]) == port and i.get("listen") == "127.0.0.1"
                and st.get("network") == "ws" and got_path == spec["path"])
        log(f"   {spec['tag']:<18} port {i['port']} path {got_path} listen {i.get('listen')} "
            f"-> {'ok' if good else 'MISMATCH'}")
        ok = ok and good
    cfg2 = panel.template()
    tags = [o.get("tag") for o in cfg2.get("outbounds", [])]
    log(f"   outbounds ({len(tags)}): {', '.join(t for t in tags if t)}")
    log(f"   routing rules ({len(cfg2.get('routing', {}).get('rules', []))})")
    for o in OUTBOUNDS:
        if o["tag"] not in tags:
            log(f"   MISSING outbound {o['tag']}"); ok = False
    for r in ROUTING_RULES:
        if not any(tuple(x.get("inboundTag") or []) == (r["inboundTag"]) for x in cfg2.get("routing", {}).get("rules", [])):
            log(f"   MISSING routing rule {r['inboundTag']}"); ok = False

    log("")
    log(f"brand      : {BRAND}")
    log(f"ports      : {', '.join(str(p) for p in ports)}"
        + ("" if used_preferred else "   (24444-24447 were busy — these are the first free run of four)"))
    log(f"result     : {'ALL CHECKS OK' if ok else 'PROBLEMS ABOVE'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
