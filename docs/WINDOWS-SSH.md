# Connecting from Windows (PowerShell)

The node is reachable **only with the private key**. There is no password:
`PasswordAuthentication no`, `PermitRootLogin prohibit-password`, key-only root.

## 1. Get the key onto your machine

The private key is in your workspace at `artifacts/private/mrphon3shop-node_ed25519`
(never committed, never printed). Copy it to a place only you can read:

```powershell
# PowerShell
New-Item -ItemType Directory -Force C:\keys | Out-Null
Copy-Item "$HOME\Downloads\mrphon3shop-node_ed25519" C:\keys\ -Force

# Windows OpenSSH refuses world-readable keys: lock the file down
icacls C:\keys\mrphon3shop-node_ed25519 /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

## 2. Connect

```powershell
ssh -i C:\keys\mrphon3shop-node_ed25519 -p 10000 root@mrphon3shop-node.tail3641f4.ts.net
```

Add a shortcut so you never type that again — `C:\Users\<you>\.ssh\config`:

```sshconfig
Host node
    HostName mrphon3shop-node.tail3641f4.ts.net
    Port 10000
    User root
    IdentityFile C:\keys\mrphon3shop-node_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 25
    ServerAliveCountMax 6
    StrictHostKeyChecking accept-new
```

then just:

```powershell
ssh node
```

## 3. First contact

```text
mrphon3shop node — mrphon3shop-node.tail3641f4.ts.net
ephemeral GitHub-hosted runner acting as a 24/7 VPS
run id: 3470…   deadline: 2026-09-12T22:2x:xxZ

node-status   → chain, lease, funnel and app state
node-apps     → installed applications + versions
...
root@mrphon3shop-node:~#
```

If you see `Permission denied (publickey)`, the key is not the one in
`manifest/trust/authorized_keys`, or the node is still booting (a fresh node needs
~2 minutes).

## 4. What to expect from a chained node

* The SSH **session drops at every handover** (every ~5h50m). That is by design:
  the machine is replaced. Reconnect with the same command and you land on the
  successor, with your files and packages intact.
* `hostname`, the Tailscale IP and the tunnel endpoint **stay the same** — the
  successor reuses the stored Tailscale identity, so your SSH config never changes.
* `node-status` tells you how much lifetime is left (`deadline_in`).
* If you get a connection refused for a minute or two right after a handover,
  the successor is still publishing the door — retry.

## 5. Useful one-liners

```powershell
# paste a local file onto the node and back
scp -i C:\keys\mrphon3shop-node_ed25519 -P 10000 .\data.zip root@mrphon3shop-node.tail3641f4.ts.net:/root/
scp -i C:\keys\mrphon3shop-node_ed25519 -P 10000 root@mrphon3shop-node.tail3641f4.ts.net:/root/out.tar.gz .

# run one command without a shell
ssh node 'node-status; node-apps | head -20'

# keep-alive while you work across a handover
ssh -o ServerAliveInterval=20 -o ServerAliveCountMax=3 node
```

## 6. Alternative: no public door at all

If you install Tailscale on your Windows machine and log into the same tailnet,
you can connect privately (no Funnel involved):

```powershell
# once, on the node (or set FUNNEL_PRIMARY_MODE=tls in config/node.env)
ssh -p 2222 root@mrphon3shop-node.tail3641f4.ts.net
```

`tailscale serve --bg --tcp=2222 tcp://127.0.0.1:22` runs automatically as a
fallback, so this path works even when the public door is down.

## 7. If it does not work

| symptom | check |
|---|---|
| `Connection refused` on port 10000 | the node may be between two runners: open the Actions tab, look at the `node` workflow, check `node-status` for `funnel` |
| `Permission denied (publickey)` | compare the fingerprint: `ssh-keygen -lf C:\keys\mrphon3shop-node_ed25519` should be `SHA256:xaiJQ49xSJQXPEIEDAjKsnC08qEK0CJRjnE4BENWnvQ` |
| `Connection timed out` | Funnel is off this boot: `Actions → manage → action=status`, or re-run `Actions → node` |
| host key changed warning | expected after a handover only if the identity was lost; remove the line with `ssh-keygen -R [mrphon3shop-node.tail3641f4.ts.net]:10000` |
