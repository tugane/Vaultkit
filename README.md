# Vaultkit

**Work for several organizations on one Mac without letting them bleed into each other.**

Vaultkit gives each organization you work for its own compartment: a Secure Enclave
SSH key, an encrypted volume, and git rules binding identity, key and signing to that
folder, then watches for those compartments drifting away from their guarantees.

## Why

If you have an employer, run your own company, and keep side projects, one Mac holds
several identities. The usual arrangement is a single SSH key, one global git identity,
and every repository readable by every process you run. A compromised dependency in one
context can read, and commit as, all of them.

Vaultkit was built after a real supply-chain compromise, out of the manual hardening
that followed. It packages a day of expert setup into a few minutes.

## What it does

- **A Secure Enclave key per organization.** Non-extractable, biometry-gated. Every
  push *and every commit* needs a physical touch, so malware cannot sign or push
  silently. It cannot use the key without you.
- **Automatic identity routing.** The right name, email, key and signing config apply
  from the folder you are standing in. Committing to one org as another stops being
  possible.
- **Encrypted per-org vaults.** An organization's code is ciphertext while you are not
  working on it. Mount when you start; secure when you finish.
- **Cloning that cannot be misrouted.** Clone into a vault and the URL, the key and the
  destination are bound together by construction, and the host must already be in your
  `known_hosts`, or the clone is refused. No trust-on-first-use.
- **A Doctor that watches for drift.** Ambient credentials, an open guard on a locked
  vault, files trapped under a placeholder, plaintext vaults in Time Machine, commits
  whose signatures do not verify.
- **A Scanner for the campaign that started all this.** Every mounted vault is watched
  for PolinRider indicators: the appended loader in both variants, the propagation
  script, the malicious npm packages, VS Code tasks that run on folder open, font files
  that are not fonts. A full pass on mount, then changed files every five minutes.
  Critical hits are neutralized on the spot: appended loaders are cut back to the
  legitimate config, artifacts and malicious packages are moved into a quarantine
  inside the vault. Restore, purge, a full history, and a notification when it acts.
  Turn auto-quarantine off and it only reports.
- **Behavioural detection, not just signatures.** A loader spliced into an import
  block carries none of the campaign's fixed strings, and the 2026 npm compromises
  split their decode calls in half purely to beat grep. So the Scanner also looks for
  the shape: decode, fetch, run, co-occurring close together. Install scripts and
  `binding.gyp` actions are read too, because both execute before anyone reads the code.
  Heuristic findings are never auto-actioned.
- **A view of what runs in the background.** Processes given their code on the command
  line, downloads piped into a shell, and every third-party item that starts itself at
  login. This family persists as a detached `node -e` plus a LaunchAgent, and neither
  shows up in a file scan.
- **Offboarding that is reversible by default.** Removing an organization takes out its
  git routing and nothing else; destroying the vault or the enclave key is a separate,
  typed-confirmation choice, and you get a receipt of what was done and what is still
  yours to do on the forge.

## Status

**Early: version 0.2.** It is used daily by its author and does real work, but it edits
your git configuration and creates encrypted volumes.

Vaultkit was open source through 0.1.0 and is commercial from 0.2.0; the source is no
longer public. A security tool you cannot read asks for more trust than one you can, so
the rest of the argument has to carry more weight: every release is signed with a
Developer ID and notarized by Apple, each one publishes its SHA-256, [SECURITY.md](SECURITY.md)
states the threat model and the trust boundaries in full, and — the part that matters
most — Vaultkit stores nothing of its own. It writes standard git config, standard
`known_hosts` entries and standard APFS volumes. Delete it and your setup keeps working.
Nothing you build with it is held hostage to it.

## What it costs

Fourteen days with every feature on, no card, no account. After that it is an annual
subscription covering up to three Macs and every update in the year.

A lapsed licence never stands between you and your own data: mounting, ejecting and
removing organizations keep working forever, and that is written into clause 6 of the
[licence](LICENSE), not just this paragraph. What a subscription covers is adding
organizations, cloning into a vault, the Scanner and the Activity view.

## Requirements

- macOS 14+ on Apple silicon (the `p-256-ne` Secure Enclave key type requires it)
- Full Xcode 15+: the Command Line Tools alone lack the SwiftUI macro plugin
- Git 2.34+ for SSH commit signing

## Install

Download the notarized DMG from <https://vaultkit.app/download>. Every release
publishes the DMG's SHA-256 so you can check what you downloaded:

```bash
shasum -a 256 ~/Downloads/Vaultkit.dmg
```

See [SECURITY.md](SECURITY.md) for what a signature does and does not prove.

## Build

For the licence holder of the source. The repository is private.

```bash
git clone git@github.com:tugane/Vaultkit.git
cd Vaultkit
swift build
swift run
```

A development build carries the placeholder signing key, so activation will refuse
every key until `Licensing.signingPublicKey` is filled in from `server/`'s keygen —
see [docs/licensing.md](docs/licensing.md). `scripts/release.sh` refuses to build a
release while the placeholder is there.

To install it as a real app in `/Applications` rather than running it from the
command line:

```bash
scripts/install-local.sh
```

That builds release, generates the icon, signs the bundle ad-hoc and installs
it. Ad-hoc means the signature is valid on the machine that built it and
nowhere else. Fine for your own use, and it is why the notarized DMG exists
for everyone else.

To develop against a local checkout of the design package:

```bash
swift package edit TuganeDesign --path ../TuganeDesign
```

Use `swift package edit`, not a SwiftPM mirror: a mirror rewrites
`Package.resolved` to `kind: localSourceControl`, which then fails to resolve
anywhere but your machine. Run `swift package unedit TuganeDesign` when done.

## How it is arranged

Vaultkit invents no database. The system is the source of truth:

| What | Where it actually lives |
|---|---|
| Identity and routing | `~/.gitconfig` includes + `~/.gitconfig-<org>` |
| Keys | The Secure Enclave; `~/.ssh/id_sk_<org>` is only a reference handle |
| Host pins | `~/.ssh/known_hosts` |
| Vault state | The APFS container, read through `diskutil` |

Delete Vaultkit and your setup keeps working. Organizations are discovered by reading
`includeIf` rules for `~/work/<org>/`, so a setup built by hand is picked up as-is.

## What it protects against, and what it does not

**It does protect against:** silent commits and pushes (each needs a touch), tampered
history reaching a forge (signing, plus server-side rules), cross-org identity mistakes,
credential theft (there is nothing durable to steal), and reading an organization's code
while its vault is locked.

**It does not protect against:** malicious code you actually execute. Anything running
as your user can read every *mounted* vault and every unvaulted file. Vaults narrow that
window to the org you are working on; they do not sandbox execution. Run dependencies
you do not trust in a container or VM.

**It is an antivirus for exactly one campaign.** The Scanner matches one published
indicator set: PolinRider's, dated in the UI, and finds nothing it has no indicator
for. Where it acts, it never destroys: the original bytes go to a quarantine inside the
vault and can be restored. The Doctor, separately, inspects configuration only.

## Security

[SECURITY.md](SECURITY.md) carries the threat model, the trust boundaries, and how to
report a vulnerability. The design documents are worth reading too:

- [Use cases](docs/use-cases.md): who it is for, and what each flow guarantees
- [Data flow](docs/data-flow.md): architecture, privilege inventory, failure modes
- [Licensing](docs/licensing.md): the trial, the gate, and the activation service

## Privacy

No telemetry, no analytics, no update check, no account.

Vaultkit makes exactly one kind of request of its own: activating a licence key, and
re-confirming it about once a week. That sends the key, a one-way hash of this Mac's
hardware UUID, and the computer's name — nothing else, ever. The trial runs fully
offline. [PRIVACY.md](PRIVACY.md) lists every field and what is kept.

The only other traffic is the SSH connection you asked for: a clone, or a verification
test you triggered. Those go straight to your forge.

## Reporting problems

Bug reports are very welcome at tooamiel@gmail.com, and security reports especially:
[SECURITY.md](SECURITY.md) says how to send one. The repository is private, so there is
no pull request to open, but a report with a reproduction gets a fix.

If you have a checkout, the services are protocol-first precisely so the system can be
faked, and anything under `Sources/Vaultkit/Services/` should come with tests.
`Tests/VaultkitTests` shows how.

```bash
swift test
```

One known wrinkle: on some toolchains `swift test` exits non-zero after all tests pass,
because the Swift Testing helper fails to load a suite that contains only XCTest cases.
Check the `Executed N tests` line rather than the exit code.

## Licence

Commercial. Copyright (c) 2026 Amiel Tugane Mutarataza, all rights reserved. See
[LICENSE](LICENSE) for the terms, [COPYRIGHT](COPYRIGHT) for the notice and
[PRIVACY.md](PRIVACY.md) for what activation sends.

Versions up to 0.1.0 were GPL-3.0-or-later. That grant stands for the copies it was
given with; it does not cover 0.2.0 or later.

Design language: [TuganeDesign](https://github.com/tugane/TuganeDesign).
