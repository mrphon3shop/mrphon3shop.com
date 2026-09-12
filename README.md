# mrphon3shop.com — a VPS that only exists as GitHub-hosted runners

A Linux node that behaves like a small always-on VPS (root SSH, apps, persistent
data, 24/7 availability) while running **only** on ephemeral GitHub-hosted
runners. Runners are destroyed every few hours by GitHub, so the system is built
around one idea:

> **the machine is disposable, the state is not.**

Every node boots from the repository, restores its data from an encrypted
*memory repository*, serves for its lifetime, hands the chain over to a successor
before GitHub kills it, and then disappears together with everything except the
encrypted state it pushed back.

---

## What you get

| capability | how |
|---|---|
| root SSH from anywhere (Windows/macOS/Linux) | OpenSSH on the node + **Tailscale Funnel** public entry on port `10000`, key-only auth |
| stable address | the next runner reuses the same node identity and the same `*.ts.net` hostname |
| persistent apps & data | per-app data/config directories snapshotted as `age`-encrypted blobs in `mrphon3shop-data` |
| reproducible software state | `manifest/packages.lock` pins every package; the memory repo stores the *resolved* inventory |
| install / uninstall that sticks | `node-install` / `node-remove` on the node, or the **manage** workflow in GitHub — the intent is recorded in the memory repo |
| 24/7 continuity | in-job watchdog dispatches the successor at T-5 min; a second watchdog in the memory repo and a keepalive cron recover from any crash |
| security on a public repository | no secret is ever committed; data is `age`-encrypted; state files are Ed25519-signed; secrets live only in GitHub Actions secrets |

## Architecture in one picture

```
        GitHub-hosted runner (ephemeral, ~5h50m)
  ┌──────────────────────────────────────────────────────────┐
  │  sshd (key only)      panel :8088     webapp :8090        │
  │      ▲                    ▲               ▲               │
  │      │ 127.0.0.1          └──── tailnet-only Serve ───────┼──► your tailnet
  │  Tailscale Funnel :10000 (public)                        │
  │      ▲                                                   │
  │  watchdog ──► dispatches the successor at T-5min         │
  └──────┬───────────────────────────────────────────────────┘
         │ encrypted blobs + signed state
         ▼
  mrphon3shop-data  (public repo = encrypted disk + watchdog cron)
         │
         ▼
  successor runner: same hostname, same data, same packages
```

Detailed documents:

* [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — lifecycle, lease protocol, failure modes
* [`docs/SECURITY.md`](docs/SECURITY.md) — threat model, secret inventory, **rotation checklist**
* [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — day-2 commands, backups, restore, tuning
* [`docs/WINDOWS-SSH.md`](docs/WINDOWS-SSH.md) — exact connection commands from Windows

---

## Daily use

Connect (after the first node is up — see `docs/WINDOWS-SSH.md`):

```powershell
ssh -i C:\keys\mrphon3shop-node_ed25519 -p 10000 root@mrphon3shop-node.tail3641f4.ts.net
```

On the node:

```bash
node-status        # chain, lease, funnel, services, packages
node-apps          # installed apps + versions and where their data lives
node-logs watchdog # follow the chain log
node-sync          # snapshot data + config into the memory repository now
node-install htop  # install now AND remember it for every future runner
node-remove htop   # uninstall and remember that too
node-service webapp restart
```

From GitHub (no SSH needed): **Actions → manage** with
`action=install|remove|sync-state|status|restart-services|dispatch-node`.

---

## How the chain survives

1. a node is dispatched (manually, by the watchdog, or by the keepalive cron);
2. it restores state, converges packages, starts services, joins the tailnet and
   publishes the Funnel door;
3. it acquires the **lease** (single writer: only one node ever serves);
4. five minutes before its deadline it dispatches a successor, which boots as a
   *standby* and restores the same data;
5. when the successor reports ready, the predecessor hands over the lease,
   releases the Tailscale name, and ends — usually with **zero gap**;
6. if anything in that chain breaks, the memory-repository watchdog notices the
   silence within 30 minutes and starts a fresh node; the keepalive cron in this
   repository is a second, independent trigger.

## Limits of the design (honest list)

* GitHub-hosted jobs are hard-capped at **6 hours**; the chain is built around a
  safe `350`-minute window plus a 5-minute overlap.
* For a **public** repository, Actions minutes are unlimited and free; a private
  repository would burn ~2,900 minutes per day of chaining.
* Every handover changes the machine (new kernel instance, new IP, ~2-4 minute
  warm-up). Long-lived TCP connections (e.g. an open SSH session) drop at
  handover — reconnect and you land on the successor.
* Public Funnel exposes the SSH port to the internet. Protection is the key
  itself (Ed25519, key-only, no password auth, rate-limited auth, no shell for
  anyone without the key). See `docs/SECURITY.md` for hardening options
  (restricting the public door to a tailnet-only `tailscale serve` is a one-line
  change if you prefer access only from your own tailnet).
* The memory repository is public: **its content is encrypted**, but its size and
  change rate are visible.

## Cost

Nothing, for this shape: GitHub-hosted runners on a public repository are free
and unmetered, and the memory repository only runs a 10-minute cron job that
usually lasts a few seconds.
