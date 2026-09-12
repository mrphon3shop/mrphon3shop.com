# Operations handbook

Everything here can be done either **on the node** (over SSH) or **from GitHub**
(Actions → `manage`). Nothing you do on a node is lost — the node pushes its
state back to the memory repository, and the next runner restores it.

## 1. The four dashboards

| what | where |
|---|---|
| lifecycle of every node | GitHub → **Actions → node** (each run writes a summary + artifacts) |
| current chain state | GitHub → the `state/heartbeat.json` in `mrphon3shop-data` |
| everything on the node | `ssh node` then `node-status` |
| web dashboard | `https://mrphon3shop-node.tail3641f4.ts.net/panel` (tailnet only) |

## 2. Installing and removing software

**A package that must exist on every future runner** (recommended):

```bash
node-install ripgrep            # installs now + records the intent in the memory repo
node-install nginx '>=1.24'     # with a version constraint
node-remove  nginx              # uninstalls + records the removal
node-remove  nginx purge        # also purge configuration files
```

From GitHub instead: **Actions → manage → run workflow**, `action=install`,
`package=ripgrep`.

What happens under the hood on every subsequent boot:

1. `scripts/30-install-packages.sh` reads `manifest/packages.lock` (pinned, in
   the public repo) **and** the operator delta (`desired.json`, stored as an
   encrypted blob);
2. it installs only what is missing or out of date;
3. it writes the resolved versions to `state/inventory.json`, which is encrypted
   and pushed back — so you always know what is actually installed;
4. drift (a pin that cannot be satisfied, a package that disappeared) is
   recorded with status `DRIFT`/`MISSING` and surfaces in `node-apps`, in the
   panel and in the run summary.

**A service you want to run** (nginx, a bot, an API…): add an entry to
`manifest/services.json` and push. The next node starts it with a systemd unit
(or a supervised process when systemd is unavailable), checks its health, and —
if `persist: true` — snapshots `data_paths` and `config_paths` into the memory
repository automatically.

```json
{
  "name": "bot",
  "enabled": true,
  "persist": true,
  "command": "/usr/bin/python3 /opt/mrphon3shop/apps/bot/main.py",
  "workdir": "/opt/mrphon3shop/apps/bot",
  "port": 8091,
  "health": { "type": "http", "path": "/healthz", "expect": 200 },
  "data_paths": ["/opt/mrphon3shop/data/bot"],
  "config_paths": ["/opt/mrphon3shop/etc/bot"],
  "tailnet_serve": { "path": "/bot", "port": 443 },
  "public": false,
  "restart": "always"
}
```

Put the program in `apps/<name>/` (code belongs in the repository); its data and
configuration belong in the two directories above, which is exactly what gets
backed up.

## 3. Data, backups, restore

* snapshots happen **every 30 minutes** and at every handover;
* `node-sync` forces one right now;
* everything lands in `mrphon3shop-data` as `blobs/<name>.tar.zst.age`, hashed in
  the signed `manifest/blobs.json`;
* to get the data out without SSH: **Actions → memory-tools → `restore`** →
  download the artifact, or run `memory_tools.py restore` locally with your age
  identity.

Blob names:

| blob | content |
|---|---|
| `appdata-<service>` | `/opt/mrphon3shop/data/<service>` |
| `appcfg-<service>` | `/opt/mrphon3shop/etc/<service>` |
| `inventory` | resolved package list |
| `desired` | your install/uninstall intent |
| `tailscale-state` | **node identity + TLS certificates** — this is why the hostname stays stable and the certificate is not re-issued on every boot |
| `system` | sshd drop-in, root `authorized_keys`, motd |

## 4. Chain surgery

```bash
# restart the chain right now (new runner, same data)
Actions → node → Run workflow        (reason=manual)

# is a node alive?
Actions → keepalive                  (runs every 10 min by itself)

# the independent watchdog, with its own history
mrphon3shop-data → state/watchdog.json
```

Tuning (all in `config/node.env`, commit and the next node picks it up):

| variable | meaning | default |
|---|---|---|
| `JOB_MAX_MINUTES` | serving window before handover (GitHub kills jobs at 360) | 350 |
| `OVERLAP_SECONDS` | how early the successor is dispatched | 300 |
| `HANDOFF_WAIT_SECONDS` | how long the predecessor waits for the successor | 420 |
| `STATE_SYNC_SECONDS` | snapshot interval | 1800 |
| `SCHEDULE_GUARD_MINUTES` | a scheduled run exits if the last heartbeat is younger | 25 |
| `FUNNEL_PRIMARY_MODE` | `tcp` (public, plain ssh) or `tls` (TLS-terminated) | tcp |
| `SMOKE_BUDGET_SECONDS` | test budget (hard cap on the whole smoke suite) | 150 |

`config/watchdog.env` in the **memory** repo controls the independent watchdog:
`STALE_MINUTES`, `DEVICE_TTL_MINUTES`, `KEEPALIVE_COMMIT`, `INTEGRITY_CHECK`.

## 5. Rotating things

| thing | how |
|---|---|
| root SSH key | generate a new keypair, add the public half to `manifest/trust/authorized_keys`, push, `manage → action=sync-keys`, then remove the old line |
| age identity | `memory-tools → rotate` (new recipient) → update `AGE_IDENTITY` in both repos |
| fleet signing key | new Ed25519 key → update `allowed_signers` in both repos → update `FLEET_SIGN_KEY` |
| Tailscale auth key | create a new key (tagged `tag:ci`, ephemeral, reusable) → update `TS_AUTHKEY` |
| workflow PAT | fine-grained PAT on both repos (`Actions`/`Contents`/`Workflows` read-write) → update `WORKFLOW_PAT` |
| operator SSH key added by hand | it is preserved: the node never clobbers `authorized_keys` |

## 6. Troubleshooting

| symptom | diagnosis | action |
|---|---|---|
| `node-status` shows `funnel=false` | the public door failed this boot | the watchdog retries 3× (`watchdog.log`); meanwhile the tailnet door on 2222 works |
| SSH drops every few hours | that is the handover | reconnect; `node-status` shows the new run id |
| run ends after ~5h50m | by design (`JOB_MAX_MINUTES`) | the successor is already serving |
| no node for a while | both watchdogs failed | run `Actions → node`; check `mrphon3shop-data/state/watchdog.json` for the reason |
| `signature_trust: unverified` in the lease | a state file was written without the fleet key | check `FLEET_SIGN_KEY`; `memory-tools → verify` lists exactly what failed |
| package installs are slow | apt is cold | ~40 s is normal on the first boot; the package stage skips everything afterwards |
| runner runs out of disk | data + logs exceeded the ~14 GB free | reduce data under `/opt/mrphon3shop`, drop `extra` packages, or shorten `STATE_SYNC_SECONDS` retention |

## 7. Emergency: bring everything up by hand

```bash
git clone https://github.com/mrphon3shop/mrphon3shop.com && cd mrphon3shop.com
export WORKFLOW_PAT=… AGE_IDENTITY=… FLEET_SIGN_KEY=… TS_AUTHKEY=…
bash scripts/prepare.sh && sudo -E bash scripts/10-bootstrap.sh
sudo -E bash scripts/70-lease.sh acquire
sudo -E bash scripts/20-restore.sh && sudo -E bash scripts/30-install-packages.sh
sudo -E bash scripts/40-apply-services.sh && sudo -E bash scripts/50-tailscale-funnel.sh
sudo -E bash scripts/60-heartbeat.sh start leader && sudo -E bash tests/smoke.sh
```

On any Ubuntu 24.04 machine this gives you the exact same node, because the node
is nothing but the repository plus the memory repository.

---

## Chain surgery (when a runner dies without handing over)

A cancelled or crashed runner cannot release its lease, so the next node would
wait for it. The operator's recovery tool releases the lease **with a signature**,
clears stale Tailscale devices that hold the stable name, and dispatches a fresh
node:

```bash
# needs the operator's local secret store (never printed, never committed)
SECRETS=~/.secrets tools/chain-surgery.sh release-lease   # free a dead holder's lease
SECRETS=~/.secrets tools/chain-surgery.sh clear-devices   # drop stale tailnet devices
SECRETS=~/.secrets tools/chain-surgery.sh reboot          # both + dispatch a node
```

The equivalent, from inside GitHub, is `Actions → manage → action=reboot-chain`
(the serving node honours it within ~60s), which is the gentler path because it
lets the current node snapshot its state first.

## "Is the public door really open?" — the honest test

`tailscale funnel status` reporting *Funnel on* only means the node asked for it.
The truth is measured the way a client experiences it (DNS → relay → TLS → sshd):

```bash
ssh node 'sudo bash /opt/mrphon3shop/work/repo/scripts/55-funnel-selftest.sh'
jq . /opt/mrphon3shop/state/funnel_selftest.json      # ok, verdict, host key fingerprint
```

The smoke suite asserts the same thing (`public-door`, `public-sshd`), the
watchdog re-runs it whenever the door is published but unverified, and the result
is published to `state/funnel.json` (`funnel.verified`).

Port note: the relay publishes A *and* AAAA records that do not always become
routable at the same moment, so the tests prefer IPv4 and the documented client
command keeps `-4` in `openssl s_client`.

---

## Operator passwords

The node is reached with `ssh root@<tailnet address>` and a password (Windows and
Android instructions: `docs/WINDOWS-SSH.md`). Accounts: `root`, plus `user` and
`mrphon` (both in `sudo`), all with the same password from the `ROOT_PASSWORD`
secret.

```bash
# change it
gh secret set ROOT_PASSWORD --repo mrphon3shop/mrphon3shop.com
# then, from GitHub:  Actions -> manage -> set-passwords
```

On the node the same thing is one command:

```bash
sudo bash /opt/mrphon3shop/work/repo/scripts/15-passwords.sh   # ROOT_PASSWORD must be in the env
```

The script also (re)writes the sshd policy: passwords are accepted **only** from
`100.64.0.0/10` / `fd7a:115c:a1e0::/48` (inside the tailnet), everything else —
most importantly the public Funnel door — stays key-only. `ALLOW_PUBLIC_PASSWORD=true`
changes that; read `docs/SECURITY.md` before you do.

## Programs that are not Debian packages

3x-ui, Mirza Bot and anything else shipped as a tarball or a git repository are
declared in `manifest/programs.json` (pinned by version — reproducibility first)
and installed by `scripts/35-programs.sh` on every boot that finds them missing:

```json
{
  "name": "x-ui",
  "version": "v3.7.0",
  "source": { "type": "github-release", "repo": "MHSanaei/3x-ui",
              "asset": "x-ui-linux-amd64.tar.gz", "strip_components": 1 },
  "install_dir": "/usr/local/x-ui",
  "binary": "x-ui",
  "link_to": "/usr/local/bin/x-ui"
}
```

Downloads land in `$WORK/program-cache` (the install root, **not** `/tmp` — that
is a small tmpfs) and are deleted after the stage; `KEEP_PROGRAM_CACHE=1` keeps
them. A marker file (`.mrphon3shop-program.json`) next to the binary records the
installed revision, so a version bump in the manifest replaces it on the next
boot and a re-run of the same version is a no-op.

The interesting part is that *nothing* about the app lives in the install
directory: databases, configs and credentials go to the `data_paths` /
`config_paths` declared in `manifest/services.json`, which are snapshotted
encrypted into the memory repository. A brand-new runner restores them before
the app is started, so the panel or bot comes back with its accounts, inbounds
and settings intact.

## The 3x-ui panel

`https://<node>.<tailnet>.ts.net:8443/xui/` — tailnet only, never public. The
panel listens on `127.0.0.1:2087` and its whole SQLite database lives in
`/etc/x-ui` (persisted). Port 2096, which 3x-ui uses for its subscription
service by default, is deliberately not used for the panel.

```bash
node-panel                     # URLs for every app + the panel login
node-status                    # is it healthy?
sudo cat /etc/x-ui/operator-credentials.json   # generated on first boot (0600)
```

The credentials are generated once, stored in `/etc/x-ui` (so they travel with
the encrypted app-data blob) and then reused for the life of the node — the
first boot prints only the path, never the values. Change the password inside
the panel (Settings → Authentication); it is written back to the same database
and therefore survives handovers.

The panel's API needs a CSRF token, like the browser does:

```bash
J=/tmp/cj; curl -s -c $J http://127.0.0.1:2087/ >/dev/null
T=$(curl -s -b $J -c $J http://127.0.0.1:2087/csrf-token | jq -r .obj)
curl -s -b $J -X POST http://127.0.0.1:2087/login -H 'Content-Type: application/json' \
     -H "X-CSRF-Token: $T" -d '{"username":"…","password":"…"}'
```

`tests/check_xui.sh` does exactly that on every boot: the panel must answer,
the generated operator must be able to log in, no default credential may be
left, and `/etc/x-ui` must be a declared data path.

## Mirza Bot (opt-in)

Declared in `manifest/services.json` with `"enabled": false` — flip it to `true`
and push when the Telegram secrets exist:

```bash
# on the node, once (hidden prompt; the value is sealed to the repo's key)
node-secret TELEGRAM_BOT_TOKEN --repo data
node-secret TELEGRAM_ADMIN_ID  --repo data
sudo systemctl restart node-heartbeat 2>/dev/null || true   # picks up the secrets
# then from GitHub:  Actions -> manage -> run workflow -> action=reboot-chain
```

What the boot does then: installs PHP 8.2 (ondrej PPA), Apache and MariaDB,
seeds `/etc/letsencrypt/live/<fqdn>` from a real `tailscale cert` so the
upstream installer skips certbot, runs it non-interactively with a generated
database password, and opens the public HTTPS door
(`tailscale funnel --https=443 https+insecure://127.0.0.1:443`). Telegram
webhooks therefore reach a node that has no stable public IP; everything else on
that machine stays tailnet-only.

Persistent paths: `/var/www/html/mirzaprobotconfig`, `/var/lib/mysql`,
`/etc/letsencrypt`, `/root/confmirza`. MySQL is snapshotted from live files —
take a `mysqldump` (or stop MariaDB) before a planned handover if you care about
a transactionally clean copy. To turn the bot off again: `enabled: false` +
push; the data stays in the memory repository.

## The operator-facing helpers

Installed on every boot into `/usr/local/bin`:

| command | what it does |
|---|---|
| `node-status` | lease, tailnet address, funnel, apps |
| `node-apps` | re-apply `manifest/services.json` (start/stop/restart) |
| `node-panel` | where every app lives + the 3x-ui credentials |
| `node-install` / `node-remove` | packages, recorded for future boots |
| `node-secret` | seal a secret into the memory repository (hidden prompt) |
| `node-sync` | push state/app data now instead of waiting for the handover |
| `node-logs <app>` | journal/log for one service |
