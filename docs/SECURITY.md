# Security model

The system is designed for a **public** repository that is continuously exposed
to the internet through Tailscale Funnel. This document states exactly what
protects what, and what you must rotate and when.

## Threat model

| attacker | goal | what stops them |
|---|---|---|
| random internet user | SSH into the node | Ed25519 key-only auth (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`), no password exists to guess, `MaxAuthTries 4`, `LoginGraceTime 20`, sshd restricted by netfilter to loopback+tailnet interfaces |
| someone who reads the public repositories | app data, secrets | **everything sensitive is `age`-encrypted** before it is committed; the private identity exists only as a GitHub Actions secret |
| someone who can push to the public repositories (fork/PR) | make a node run attacker code | workflows only run on `main` and on `workflow_dispatch` from the repository itself; PRs from forks never run with secrets; the *desired-state delta* is stored inside an encrypted blob and is restricted to `apt`/`bin` entries by `20-restore.sh` before anything executes |
| someone with write access to the memory repository | fake a lease, replay old data | plaintext state is Ed25519-**signed** and the node refuses unsigned/invalid leases; blob hashes come from the signed `manifest/blobs.json`; encrypted blobs are AEAD-protected (rollback of an *old valid* blob is possible — see *residual risks*) |
| someone who steals a runner's disk image mid-job | full state | runner disks are destroyed with the job; secrets are injected at run time, never written to the repository |
| a compromised dependency in `manifest/packages.lock` | persistence | every package is pinned and visible in a public diff; the memory repo records the resolved versions so drift is visible |

## Secrets inventory

| secret | where | what it can do | rotation |
|---|---|---|---|
| `TS_AUTHKEY` | node repo | join the tailnet as `tag:ci` (ephemeral, reusable, 90 days) | create a new key in the Tailscale admin console (or via API), update the secret, revoke the old key |
| `TS_API_TOKEN` | memory repo | list/delete devices in your tailnet | generate a new API key, update the secret, revoke the old one |
| `WORKFLOW_PAT` | both repos | dispatch workflows, push the encrypted state, read/write repo contents | **replace with a fine-grained PAT**: only `mrphon3shop.com` + `mrphon3shop-data`, permissions `Actions: read/write`, `Contents: read/write`, `Workflows: read/write`, expiry ≤ 90 days; then revoke the old token |
| `AGE_IDENTITY` | both repos | decrypt every blob in the memory repository | `Actions → memory-tools → rotate` with a new recipient, then update the secret |
| `FLEET_SIGN_KEY` | both repos | sign leases/heartbeats/blob index | generate a new Ed25519 key, append the public half to `manifest/trust/allowed_signers` and the memory repo's `keys/allowed_signers`, then swap the secret |
| root SSH private key | **your machine only** | log in as root | generate a new keypair, append the public half to `manifest/trust/authorized_keys`, run `manage → sync-keys`, remove the old line |
| Tailscale account password / PAT from the original notes file | your password manager | everything | **rotate now**: those values were stored in plaintext and must be considered compromised |

## Hard rules enforced by the code

1. `manifest/trust/*` contains **only public keys**; the secret scanner in
   `selftest.yml` fails the build if a token-like string ever appears in the tree.
2. Nothing is logged that could contain a secret: scripts print fingerprints
   (`<183 bytes, sha256:3ee9e0c0>`), never values; `watchdog.py` redacts secrets
   from any API error message.
3. The node verifies secrets against the trust anchors at boot
   (`scripts/prepare.sh`) and refuses to continue on a mismatch.
4. Root SSH is key-only; the operator key in `authorized_keys` is restricted with
   `no-agent-forwarding,no-X11-forwarding,no-user-rc,permitopen="127.0.0.1:22"`.
5. The node's `authorized_keys` is populated from the repository, but never
   clobbered — operator keys added at runtime are kept.
6. Public exposure is limited to one TCP port (the SSH door). The panel and every
   application are tailnet-only (`tailscale serve`, never `funnel`).

## Residual risks you should know about

* **Public Funnel is public.** Anyone can open a TCP connection to
  `mrphon3shop-node.<tailnet>.ts.net:10000`. They cannot authenticate without the
  key, but they can consume connection slots. If that bothers you, set
  `FUNNEL_PRIMARY_MODE=tls` and use `tailscale serve` (tailnet-only) instead —
  see *Tailnet-only mode* below.
* **Rollback of a valid old blob.** An attacker with write access to the memory
  repository could re-publish an older but correctly signed blob (e.g. a config
  from a week ago). Mitigation: the blob index is signed and monotonic
  (`seq` increases) — alert on a decreasing `seq` in `manifest/blobs.json`.
* **The `runner` user on the node can `sudo` without a password** (that is how
  GitHub runners work). Anything running as `runner` can read the node's secrets
  for that run — it is the same machine, and it dies with the run.
* **GitHub is the root of trust.** If someone can change the workflows on `main`,
  they control the node. Protect `main` with a ruleset if you add collaborators.

## Tailnet-only mode (public surface = zero)

```yaml
# config/node.env
FUNNEL_PRIMARY_MODE=tls      # tls-terminated-tcp on 8443 instead of raw tcp on 10000
TAILNET_SSH_FALLBACK=true    # keep the tailnet-only door on 2222
```

Or disable the public door completely and connect through the tailnet:

```bash
# on the node
tailscale serve --bg --tcp=2222 tcp://127.0.0.1:22
# from your machine (needs its own Tailscale login)
ssh -p 2222 root@mrphon3shop-node.tail3641f4.ts.net
```

## Rotation runbook (do this today)

1. **Revoke the old Tailscale API token** and the initial auth key in the
   Tailscale admin console → *Settings → Keys*.
2. **Create a fine-grained PAT** (only the two repositories, `Actions` +
   `Contents` + `Workflows`) and run, in both repositories:
   `Settings → Secrets and variables → Actions → WORKFLOW_PAT → Update`.
3. **Revoke the old classic token** on GitHub → *Settings → Developer settings*.
4. **Change the Tailscale account password.**
5. Verify: `node-status` shows `signature_trust: ok`, and
   `Actions → memory-tools → verify` reports zero failures.

---

## The public door is a TLS door (why the ssh command looks unusual)

Tailscale Funnel relays are shared between tailnets and route an incoming
connection to the right node **by the TLS SNI**, so every public connection must
begin with a TLS handshake. Measured on a real runner with Tailscale 1.102.4:

| Funnel mode | what a plain ssh client sees |
|---|---|
| `--tcp=10000` (raw) | nothing: the relay waits for a ClientHello |
| `--tls-terminated-tcp=10000` | the relay completes TLS, then hands the **plaintext** stream to sshd → ssh works inside the tunnel |

So the node publishes `--tls-terminated-tcp` (10000 primary, 8443 as a second
door) and the client wraps its stream (`openssl s_client`, or the bundled
`tools/windows/tls-tunnel.ps1`). The tailnet door (`serve --tcp=2222`) needs no
wrapper at all — that is the recommended path once Tailscale is installed on the
operator's machine.

## Root keys are a whitelist, and the image's keys are quarantined

GitHub's Ubuntu runner image ships `/root/.ssh/authorized_keys` entries of its own
(`packer`, `Azure Deployment`). Since this node is publicly reachable, a leftover
image key would be a takeover path, so:

* `scripts/10-bootstrap.sh` rebuilds the file from `manifest/trust/authorized_keys`
  plus the operator's own additions;
* `scripts/20-restore.sh` restores that list from the encrypted `system` blob but
  **quarantines** anything matching `packer|azure deployment|microsoft`;
* the `key-allow` smoke check fails the boot if any other key can log in.

## Operator channel (`state/ops.json`)

The serving node polls `state/ops.json` in the memory repository once a minute.

```json
{"handoff": true, "requested_at": "2026-09-12T17:20:00Z", "requested_by": "operator"}
```

`handoff: true` means "give the chain to a fresh runner now" — the equivalent of a
reboot. It contains no secret: like the lease, it is coordination data. Write it
with `Actions → manage → handoff-node`, or by hand

```bash
scripts/96-ops-request.sh handoff    # 96-ops-request.sh clear  to withdraw
```

---

## Password access: inside the tailnet, never in public

The operator's daily login is a password (`ssh root@100.66.254.29` after joining
the tailnet). That is deliberate and scoped:

```
# /etc/ssh/sshd_config.d/00-runner-vps.conf  (written by scripts/15-passwords.sh)
PermitRootLogin prohibit-password      # global: keys only
PasswordAuthentication no              # global: keys only
AllowUsers root mrphon user
...
# ---- password door: inside the tailnet only ----
Match Address 100.64.0.0/10,fd7a:115c:a1e0::/48
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    PermitRootLogin yes
    AuthenticationMethods any
    MaxAuthTries 4
```

Why a `Match` block instead of just turning passwords on:

* the **public Funnel door arrives on loopback** (the relay connects to
  `tcp://127.0.0.1:22`), so a loopback source keeps the key-only policy — a public
  visitor can never try a password, no matter how long they scan;
* **tailnet connections arrive from `100.x`**, i.e. inside WireGuard, from devices
  that already authenticated to your tailnet — password auth there adds no
  internet-facing attack surface;
* the `serve` door on 2222 is proxied through loopback as well, so it also stays
  key-only (verified: `Password denied (publickey)` from a peer).

Verified end to end from a real tailnet peer (a throwaway node joined for the
test, then removed):

```
sshd banner seen by the peer: SSH-2.0-OpenSSH_9.6p1 Ubuntu-3
attempt 1 (root, password only)      -> PASSWORD_LOGIN_OK
attempt 2 (root via serve port 2222) -> Permission denied (publickey)   # by design
attempt 3 (user, password only)      -> USER_LOGIN_OK
```

`PasswordAuthentication` is also asserted per source address in the smoke suite
(`tests/check_sshd.sh`): tailnet `yes`, loopback `no`, public `no`.

### If you really want the password on the public door

`config/node.env` → `ALLOW_PUBLIC_PASSWORD=true`, then `Actions → manage →
reboot-chain`. Understand what that means first:

* the door is reachable by every scanner on the internet within minutes;
* the password is 9 characters, alphanumeric, and has been typed into chats and
  files, so treat it as known;
* the only thing slowing an attacker down would be `MaxAuthTries`; there is no
  lockout or fail2ban on an ephemeral runner.

The recommended combination is exactly what is configured: **password inside the
tailnet, key on the public door.**

### Rotating the password

```bash
gh secret set ROOT_PASSWORD --repo mrphon3shop/mrphon3shop.com   # new value
Actions -> manage -> set-passwords                                # applies it now
```

`scripts/15-passwords.sh` pipes the secret straight into `chpasswd`: it never
reaches a log line, a process argument list or a file, and it is `unset`
immediately afterwards.

## Panel and application data

The 3x-ui panel listens on `127.0.0.1:2087` only and is reached through the
tailnet (Tailscale serve on 8443, path `/xui`). Its database — including the
operator password hash and every inbound — lives in `/etc/x-ui`, and its
generated credentials in `/etc/x-ui/operator-credentials.json` (0600). Both go
into the memory repository as part of the encrypted `appdata-x-ui` blob, so the
public repository never sees them; the blob is age-encrypted to the node key.

Mirza Bot is the only service that publishes a **public** HTTPS door (Funnel on
443), because Telegram must be able to deliver webhooks. It brings its own
authentication (bot token + admin id + the Mini App's login), its certificate is
a real Let's Encrypt one for the node's `*.ts.net` name, and its database
password is generated per node and stored in `/root/confmirza` — also encrypted
into the memory repository. The public door is HTTPS and points at a single
Apache vhost; no shell access is exposed there (SSH over the Funnel door stays
key-only).
