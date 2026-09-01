# Vaultkit

A macOS app for developers who work for multiple companies on one Mac.

Vaultkit sets up and maintains **per-organization isolation** so that a compromise
in one company's context cannot push to, read from, or reuse credentials against
another's:

- **Secure Enclave SSH keys** per organization — unextractable, Touch ID-gated
- **Automatic git identity routing** — the right name/email/key per folder, enforced
- **SSH commit signing** — every commit and amend requires a physical touch
- **Encrypted per-org vaults** — an organization's code is ciphertext when not in use
- **Doctor** — continuous drift detection (ambient tokens, unpinned hosts, open guards)
- **Prompt attribution** — explains which process caused an unexpected Touch ID prompt

Born from a real supply-chain incident (PolinRider) and the manual hardening that
followed. Vaultkit packages that day of expert work into a ten-minute wizard.

## Status

Early scaffold. Design documents live in [docs/](docs/):

- [Use cases](docs/use-cases.md)
- [Data flow](docs/data-flow.md)

## Development

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build   # compile
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run     # launch
```

Requires macOS 14+ and **full Xcode** (the bare Command Line Tools lack the
SwiftUI macro plugin on current SDKs — `@State` fails to compile without it).
Alternatively run `sudo xcode-select -s /Applications/Xcode-beta.app` once and
drop the `DEVELOPER_DIR=` prefix.

## Security principles (non-negotiable)

1. **Vaultkit never sees a secret.** Passphrases are entered in system dialogs;
   private keys live in the Secure Enclave; no token or password is ever stored,
   logged, or transmitted by the app.
2. **The user's config files are the source of truth.** Vaultkit reads and
   *surgically patches* `~/.gitconfig`, `~/.ssh/config`, etc. — it never clobbers
   content it did not write, and every change is previewed before it is applied.
3. **Zero network.** No telemetry, no update phone-home, no cloud. The only
   outbound connections are the SSH verification tests the user explicitly runs.
4. **Everything is reversible.** Every setup step has a documented, one-click undo.
