# Security

Vaultkit is a security tool, so it owes you a precise account of what it guarantees,
what it does not, and where you still have to trust something.

## Reporting a vulnerability

Please report privately rather than opening a public issue: use GitHub's
**Security → Report a vulnerability** on this repository. Include what you did, what
happened, and the macOS and Xcode versions. You will get an acknowledgement within a
week. There is no bounty; there is credit, and a fix.

## Threat model

Vaultkit is built for a developer whose single Mac holds several work identities. The
adversary it is designed against is **code you did not intend to run** executing as
your user — a poisoned dependency, a malicious build script, an editor plugin — plus
anyone with physical access to the disk.

It assumes macOS itself, the Secure Enclave, APFS encryption and OpenSSH are sound.
If the kernel is compromised or the attacker has root, nothing here helps.

## What it guarantees

**Keys cannot be stolen.** Each organization's SSH key is generated inside the Secure
Enclave as a non-extractable `p-256-ne` identity. `~/.ssh/id_sk_<org>` is a reference
handle, not a key: copied to another machine it is worthless. Every use requires
biometric confirmation, so malware cannot authenticate, sign, or push while you are
away — and an unexpected prompt is a tripwire telling you something tried.

**Identity cannot be crossed.** Routing is path-based through git's `includeIf`, with
`IdentitiesOnly=yes` so no other key is ever offered. Cloning through Vaultkit binds
URL, key and destination in one operation.

**History cannot be tampered with silently.** Commits are SSH-signed by the same
enclave key, so producing a valid signature also needs a touch. Malware that amends a
commit either triggers an unexpected prompt or leaves the commit unsigned — visible
locally and rejectable by a forge that requires signatures.

**Data at rest is unreadable.** Each organization's code lives on an encrypted APFS
volume that is ciphertext while ejected.

**Hosts are pinned.** Clones are refused for hosts absent from `known_hosts`. There is
no trust-on-first-use path in the app.

**Nothing durable is stored.** Vaultkit keeps no tokens, no passwords, no passphrases,
and has no network client of its own.

## What it does not guarantee

**It does not sandbox execution.** This is the important limit. Anything running as
your user can read every *mounted* vault, every unvaulted file, and your home
directory. Vaults reduce exposure in *time* — only the org you are working on is
readable — they do not isolate processes. Run untrusted code in a container or VM.

**It cannot stop you approving a malicious prompt.** The touch is the last line of
defence; if you approve prompts you did not initiate, the guarantees fall.

**It does not protect a compromised forge or teammate.** Server-side rules — required
signatures, protected branches, enforced 2FA — are complementary and Vaultkit cannot
apply them for you.

**It does not detect malware in general.** The Doctor inspects configuration state. The
Scanner matches a specific, published indicator set — the PolinRider campaign's loaders,
artifacts, packages and infrastructure — in mounted vaults, and shows that set's date.
Anything without an indicator in it is invisible to the Scanner. It reads bytes and
writes nothing; remediation is yours, with the published steps shown beside each hit.

## Trust boundaries

| Operation | Mechanism | Privilege | Secret exposure |
|---|---|---|---|
| Key creation / listing | `sc_auth` | user | none — the key is born in the enclave |
| Reference key export | `ssh-keygen -K` | user | none — a handle, useless alone |
| Vault create / mount / eject | `diskutil apfs` | user | passphrase (see below) |
| Identity and signing config | direct file IO | user | none |
| Host pinning, clone, auth test | `ssh`, `git` | user | signature via enclave + touch |
| Prompt attribution | `ps`, `lsof` | user | none |
| Indicator scan of mounted vaults | direct file IO, read-only | user | none — file bytes are matched, never sent or stored |
| Destroy a vault / delete an identity | `diskutil apfs deleteVolume`, `sc_auth delete-ctk-identity` | user | none — typed confirmation, refused while mounted, verified against the system afterwards |

**No component runs as root, and no privileged helper is installed.**

### The one deviation worth naming

The design intends that passphrases never transit the app. `diskutil` offers no GUI
prompt when driven programmatically, so mounting and vault creation take the passphrase
in a `SecureField` and pipe it to `-stdinpassphrase`. It passes through app memory once,
is never written to disk or logged, and the field is cleared on submit. Moving to a
DiskArbitration-based unlock, where macOS owns the dialog, is the intended fix.

Vault passphrases are deliberately **not** stored in the login keychain. A keychain-held
passphrase would let any process mount the vault silently, which defeats the point.

## Hardening assumptions you should verify yourself

Vaultkit trusts the machine it runs on. Independently: keep FileVault on so anything
outside a vault is also encrypted at rest, keep vaults out of unencrypted backups (the
Doctor checks Time Machine), and enable required-signature and protected-branch rules on
your forges so tampered history is rejected server-side rather than merely flagged
locally.

## What a release signature does and does not prove

Releases are distributed as a notarized DMG signed with a Developer ID certificate, and
each release publishes the DMG's SHA-256. That proves the build came from the holder of
that certificate and has not been altered in transit — it does **not** prove the binary
was built from the source in this repository. No signature can.

Building from source remains fully supported and is the higher-assurance path:

```bash
swift build -c release
```

There is no auto-update channel. Vaultkit never checks for, downloads, or installs
anything; a new version only ever arrives because you fetched it deliberately.
