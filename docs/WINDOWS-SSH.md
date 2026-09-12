# Connecting from Windows (PowerShell)

Two doors, both key-only, both to this same node. Use whichever fits:

| door | who can reach it | what the command looks like |
|---|---|---|
| **tailnet** (recommended) | your Windows PC with the Tailscale client installed and logged into your tailnet | `ssh node` — plain ssh, no tricks |
| **public Funnel** | any network, nothing to install except the key (and `openssl`) | one long line with a TLS wrapper (below) |

Everything below is verified against the live node: `root` login with
`mrphon3shop-node_ed25519`, sshd banner inside the tunnel, Let's Encrypt
certificate for `mrphon3shop-node.tail3641f4.ts.net`.

---

## 0. One-time setup on Windows

```powershell
New-Item -ItemType Directory -Force C:\keys | Out-Null
Copy-Item "$HOME\Downloads\mrphon3shop-node_ed25519" C:\keys\ -Force
```

### Fix the key permissions (do this properly, `ssh` will refuse otherwise)

Windows' OpenSSH refuses a key that other accounts can read, and a file copied
from Downloads usually inherits an `Authenticated Users` entry. The reliable fix:

```powershell
$k = "C:\keys\mrphon3shop-node_ed25519"
takeown /f $k
icacls $k /inheritance:r
$who = @("NT AUTHORITY\Authenticated Users","BUILTIN\Users","Everyone","NT AUTHORITY\SYSTEM","BUILTIN\Administrators")
foreach ($a in $who) { icacls $k /remove:g $a 2>$null }
icacls $k /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(R)"
icacls $k          # verify: only your own account should be listed
```

Only after that does `ssh` load the key.

### Shortcut: let the script do all of it

`tools/windows/connect-node.ps1` locks the key down, picks the tailnet door when
Tailscale is running, otherwise wraps the public door in TLS (using `openssl`
if it exists, else a built-in .NET tunnel it installs for you):

```powershell
.\connect-node.ps1                      # interactive shell on the node
.\connect-node.ps1 -RemoteCommand node-status
```

---

## 1. Recommended: the tailnet door (plain ssh, survives every handover)

Install Tailscale for Windows (one minute, GUI), log into the same tailnet, then:

```powershell
ssh -i C:\keys\mrphon3shop-node_ed25519 root@mrphon3shop-node.tail3641f4.ts.net
```

That is the whole thing. MagicDNS resolves the name to the node's tailnet
address while Tailscale is connected, so no ports, no TLS wrapper, no Funnel.

Permanent shortcut — put this in `C:\Users\<you>\.ssh\config` and simply type
`ssh node` afterwards:

```sshconfig
Host node
    HostName mrphon3shop-node.tail3641f4.ts.net
    User root
    Port 22
    IdentityFile C:\keys\mrphon3shop-node_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 25
    ServerAliveCountMax 6
    StrictHostKeyChecking accept-new
```

(If something is listening on 22 for another reason, the node also publishes a
tailnet-only door on 2222: `Port 2222` works identically.)

---

## 2. The public Funnel door (no Tailscale client needed)

Tailscale Funnel relays demultiplex incoming connections **by the TLS SNI**, so
the public door is always a TLS door: the client wraps its ssh stream in TLS and
the relay hands the plaintext to the node's sshd. Verified working:

```powershell
ssh -p 10000 -i C:\keys\mrphon3shop-node_ed25519 `
    -o "ProxyCommand=openssl s_client -4 -quiet -connect %h:%p -servername %h" `
    -o UserKnownHostsFile=$HOME\.ssh\known_hosts `
    root@mrphon3shop-node.tail3641f4.ts.net
```

`openssl.exe` ships with **Git for Windows** (`C:\Program Files\Git\usr\bin\`).
If it is not on `PATH`, use the full path:

```powershell
ssh -p 10000 -i C:\keys\mrphon3shop-node_ed25519 `
    -o "ProxyCommand=C:\Program Files\Git\usr\bin\openssl.exe s_client -4 -quiet -connect %h:%p -servername %h" `
    root@mrphon3shop-node.tail3641f4.ts.net
```

### No openssl on the machine? Use the bundled wrapper

`tools/windows/tls-tunnel.ps1` (in this repository) does the TLS handshake with
.NET and bridges it to ssh — no dependencies at all:

```powershell
Copy-Item .\tools\windows\tls-tunnel.ps1 C:\keys\ -Force

ssh -p 10000 -i C:\keys\mrphon3shop-node_ed25519 `
    -o "ProxyCommand=powershell -NoProfile -ExecutionPolicy Bypass -File C:\keys\tls-tunnel.ps1 %h %p" `
    root@mrphon3shop-node.tail3641f4.ts.net
```

Or as a shortcut in `.ssh\config`:

```sshconfig
Host node-public
    HostName mrphon3shop-node.tail3641f4.ts.net
    User root
    Port 10000
    IdentityFile C:\keys\mrphon3shop-node_ed25519
    ProxyCommand powershell -NoProfile -ExecutionPolicy Bypass -File C:\keys\tls-tunnel.ps1 %h %p
```

Port `8443` is published as a second door (same TLS mode) for networks that
filter high ports: swap `-p 10000` for `-p 8443`.

---

## 3. First contact

```text
mrphon3shop node — mrphon3shop-node.tail3641f4.ts.net
ephemeral GitHub-hosted runner acting as a 24/7 VPS

node-status   → chain, lease, door and app state
node-apps     → installed applications + versions
...
root@mrphon3shop-node:~#
```

Confirm you are talking to the real node (the fingerprint is printed by
`node-status`, and it stays the same across handovers):

```powershell
ssh node 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'
```

## 4. What to expect from a chained node

* The ssh **session drops at every handover** (about every 5h50m). Reconnect with
  the same command: your files, packages, services and the hostname are restored
  from the memory repository.
* `node-status` shows `deadline_in=…`, the current run id and the lease holder.
* Right after a handover the door can refuse connections for a minute or two
  while the successor publishes it — retry.
* The **host key fingerprint becomes stable** once the first node of the new code
  has synced its state (`system` blob); `ssh` will warn exactly once if it changed.

## 5. Handy commands

```powershell
# run one command, no interactive shell
ssh node 'node-status; node-apps | head -20'

# copy files in and out (the tailnet door is the fastest)
scp -i C:\keys\mrphon3shop-node_ed25519 .\backup.zip root@mrphon3shop-node.tail3641f4.ts.net:/root/
scp -i C:\keys\mrphon3shop-node_ed25519 root@mrphon3shop-node.tail3641f4.ts.net:/opt/mrphon3shop/state/smoke.json .
```

## 6. Troubleshooting

| symptom | cause / fix |
|---|---|
| `Permission denied (publickey)` | wrong key or the node is still booting. The only accepted key is the one in `manifest/trust/authorized_keys` (fingerprint `SHA256:xaiJQ49xSJQXPEIEDAjKsnC08qEK0CJRjnE4BENWnvQ`) |
| `Connection closed by UNKNOWN port 65535` on the public door | the TLS wrapper is missing (`ProxyCommand` not applied) — Funnel drops non-TLS connections by design |
| `unexpected eof while reading` | the relay has A and AAAA records that do not always become routable together: keep `-4` in `openssl s_client`, or retry |
| `Connection refused` on 10000 | between two runners, or the door is being republished: retry in a minute, or check `Actions → manage → action=status` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | the node regenerated its host keys (only possible before the `system` blob was first synced): `ssh-keygen -R mrphon3shop-node.tail3641f4.ts.net` |
| `Host key verification failed` | add `-o StrictHostKeyChecking=accept-new` once, then compare the fingerprint with `ssh-keygen -lf C:\keys\mrphon3shop-node_ed25519` |
