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
