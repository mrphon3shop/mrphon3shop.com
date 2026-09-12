# trust anchors

| file | what it is | safe in a public repo |
|---|---|---|
| `authorized_keys` | public half of the root SSH key installed on the node | yes (public key only) |
| `fleet_sign.pub` | verifies signatures on the plaintext state files in the memory repo | yes |
| `allowed_signers` | `ssh-keygen -Y verify` allow-list used by the node | yes |
| `memory_recipient.txt` | age public key: the only key that can decrypt the memory repo | yes |

Private halves live **only** in GitHub Actions secrets (`AGE_IDENTITY`, `FLEET_SIGN_KEY`)
and on your own machine. They must never be committed.

Rotating the deploy key = append the new public key to `authorized_keys`, push,
run the `manage` workflow with `action=sync-keys`, then remove the old line.
