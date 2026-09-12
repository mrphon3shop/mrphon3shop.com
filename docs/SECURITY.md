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
