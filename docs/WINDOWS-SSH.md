# Connecting from Windows or Android — the simple way

**One line, then your password:**

```powershell
ssh root@100.66.254.29
```

That is the whole procedure. Two prerequisites, once per device:

1. install **Tailscale** (Windows: tailscale.com installer; Android: Play Store),
2. log in to your tailnet and switch it on.

Then `ssh root@100.66.254.29` — the node's tailnet address — and type the
operator password. The same works on Android:

```bash
pkg install openssh && ssh root@100.66.254.29
```

Prefer names? `ssh root@mrphon3shop-node` resolves too (MagicDNS short name).

Operator accounts (same password): **`root`**, **`user`**, **`mrphon`**
(the latter two are in `sudo`; `sudo -i` to become root).

---

## Why the tailnet address and not the public door?

Passwords are accepted **only from inside your Tailscale tailnet**. The public
Funnel door is open to the whole internet, so it stays key-only: internet-facing
password authentication is the fastest way to lose a machine to a botnet, and
`root` + a 9-character password would not survive a day of scanning.

| path | who can use it | login |
|---|---|---|
| tailnet (what you have on your PC/phone) | your own devices only, WireGuard-encrypted | password **or** key |
| public Funnel door, port 10000 | anyone on the internet | key only |
| tailnet port 2222 (serve) | your own devices | key only |

Full details, including the exact `sshd_config` match block, are in
`docs/SECURITY.md`. If you ever want the public door to accept the password too,
flip `ALLOW_PUBLIC_PASSWORD=true` in `config/node.env` and run
`Actions → manage → reboot-chain` — the trade-off is written up there.

---

## Addresses, and how stable they are

| what | value | stable across handovers? |
|---|---|---|
| tailnet address | `100.66.254.29` | yes — the node restores its Tailscale identity on every boot |
| tailnet name | `mrphon3shop-node` / `mrphon3shop-node.tail3641f4.ts.net` | yes, always |
| public door (optional) | `ssh -p 10000 -i <key> root@mrphon3shop-node.tail3641f4.ts.net` | name yes, key required |

Check the current address at any time from GitHub: the `state/funnel.json` file in
`mrphon3shop-data` lists `tailnet_ip`.

---

## After you are in

```bash
node-status      # chain, lease, door, disk, services
node-apps        # installed applications + exact versions
node-install X   # install a package now and on every future node
node-sync        # force a snapshot of your data to the memory repository
sudo -i          # full root shell (from user/mrphon)
```

## If it does not connect

| symptom | cause / fix |
|---|---|
| `Connection timed out` | Tailscale is off on your device, or you are logged into a different tailnet |
| `Permission denied` | wrong user or password — use `root`, `user` or `mrphon` |
| `Connection refused` | the chain is between two runners; retry in a minute |
| name does not resolve on Android | use the address: `ssh root@100.66.254.29` |
| want to see it from GitHub instead | `Actions → manage → action=status` |

Sessions drop at each handover (roughly every 5h50m): reconnect with the same
command and you land on the successor with the same hostname, address, files and
packages.
