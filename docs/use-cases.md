# Vaultkit — Use Cases

## Personas

| # | Persona | Situation | What they need |
|---|---------|-----------|----------------|
| P1 | **The multi-hat developer** | Employed at company A, runs company B, co-founded C — all on one Mac | Hard guarantees that contexts can't bleed: wrong-identity commits, cross-org credential reuse, one org's compromise reaching another |
| P2 | **The freelancer/consultant** | Rotating client engagements, NDAs, client-owned code | Fast per-client onboarding *and* clean offboarding — prove client code and access are gone when the contract ends |
| P3 | **The post-incident rebuilder** | Just wiped their machine after malware (the founding story) | A trustworthy path from blank Mac to hardened setup in minutes, not a day of expert hand-holding |
| P4 | **The team lead** | Wants every developer on the team set up identically | An exportable recipe; a posture check they can ask everyone to run |

## Design invariants (apply to every use case)

- **I1 — No secret ever enters the app.** Passphrases go into system dialogs; keys live in the Secure Enclave; Vaultkit stores no token, password, or passphrase.
- **I2 — Config files are the source of truth.** Vaultkit derives state by reading `~/.gitconfig`, `~/.ssh/*`, `diskutil`, `sc_auth` — its own cache is disposable.
- **I3 — Every mutation is previewed.** The user sees the exact diff/command before anything is written, and every write has a documented undo.
- **I4 — Fail closed.** A cancelled or failed step must leave the system at least as protected as before (e.g. a failed vault unlock re-closes the placeholder guard).
- **I5 — Explain, don't just do.** Each step shows *why* it exists (one sentence + expandable detail) — the app teaches the security model it installs.

---

## UC1 — Onboard the first organization (the wizard)

**Persona:** P1–P3 · **Goal:** from nothing to a verified, isolated org context.

**Preconditions:** none (a virgin machine is the design target).

**Main flow:**
1. User enters: org name, display name, commit name/email, forge type (GitHub / GitLab / Gitea / custom), forge host.
2. Vaultkit probes the forge (read-only): detects Gitea-style API, **detects non-standard SSH ports** (e.g. built-in Go SSH on 2222), fetches host-key fingerprints.
3. Host-key verification: for known forges, compare against published fingerprints automatically; for custom forges, walk the user through out-of-band verification (console command to run on the server, second-network cross-check) before pinning.
4. Create the Secure Enclave identity (`sc_auth create-ctk-identity … -t bio`) — with a **clamshell-mode preflight**: detect lid-closed/Touch-ID-unavailable *before* attempting and tell the user to open the lid.
5. Export the reference key into `~/.ssh` with a canonical name; show the public key with copy button and a **deep link to the exact forge page** to paste it (Settings → SSH keys, per forge type), including "delete keys from before your rebuild" guidance.
6. Preview + apply config: `includeIf` block, per-org identity file, `core.sshCommand` with `IdentitiesOnly` and the enclave provider.
7. **Verify live**: run the SSH auth test, show the forge's greeting ("Hi username!") as proof. Retry loop until the user finishes the browser step.

**Alternate flows:**
- 4a. Touch ID unavailable (clamshell/no sensor) → explain, watch for lid-open, resume automatically.
- 7a. Auth fails → diagnose: key not registered yet vs. wrong account vs. SSO authorization missing vs. wrong port; show the specific fix.

**Postcondition:** a folder exists whose git operations use the right identity and key, verified end-to-end.

## UC2 — Add another organization

Same as UC1 minus first-run setup; additionally verifies **cross-org isolation** after adding: each org's key authenticates only to its own account (parallel auth tests, distinct greetings shown side by side).

## UC3 — Enable commit signing for an org

**Goal:** every commit/amend requires Touch ID; tampered history is visible and (with server rules) unpushable.

1. Toggle signing for the org → preview config diff (`gpg.format=ssh`, signing key, `commit.gpgsign`, allowed-signers entry).
2. Guide the forge-side half: register the same public key as a **signing key** (per-forge path; GitLab's delete-and-re-add quirk handled), enable vigilant mode where the forge has one.
3. Verify: create a throwaway signed commit (user is warned: one Touch ID prompt), check `git log --show-signature` locally; after first real push, confirm the Verified badge.
4. Explain the tripwire/wall model: unexpected signing prompt = tripwire; server "require signed commits" = wall. Offer a checklist item for the org's branch rules.

## UC4 — Create a vault for an org

**Goal:** the org's code is ciphertext except while actively being worked on.

1. Explain the temporal model (mounted = exposed, locked = gone) and the passphrase rules (unique, stored off-machine, **never** in the keychain).
2. Create the encrypted APFS volume — passphrase entered in the system prompt, not the app (I1).
3. Migrate existing folder contents onto the volume; mount at the canonical `~/work/<org>` path so all config keeps working; close the placeholder guard.
4. Verify a full mount → identity-check → eject cycle with the user.

**Alternate:** org folder has contents while vault is locked (shadowing hazard) → detect, surface, offer merge-on-next-mount.

## UC5 — Daily vault lifecycle (menu bar)

- Mount/eject any org from the menu bar; states: none / locked / **mounted (exposed)** / busy.
- Eject dissent handling: name user-level holders ("Terminal tab in ~/work/rmsoft", "VS Code window"); recognize **root-level holders** (Spotlight indexing, antivirus scan) that user tools can't see — auto-retry with backoff instead of failing cryptically (I4).
- Optional nudges: "WeCreate has been mounted for 6h — still using it?"; "You're about to run an installer with 2 vaults mounted — eject first?"

## UC6 — Doctor (drift detection)

**Goal:** the setup keeps its guarantees over time; runs read-only (I2).

Checks include:
- Ambient credentials outside org folders (e.g. a gh/glab login in the default config dir, legacy keyring entries)
- Identity leaks: a repo under an org folder resolving the wrong email/key; `useConfigOnly` missing
- Signing drift: org configured for signing but key not registered on the forge; unsigned recent commits in a signing-enabled org
- Host-pin drift: known_hosts entry changed vs. pinned fingerprint
- Vault hygiene: placeholder guard left open (writable while locked); content trapped under a mount point (shadowed files); vault passphrase found in the login keychain (violation of the model)
- Machine posture: FileVault state (report once, respect the user's decision), Gatekeeper, unexpected launch agents (informational)

Each finding: severity, plain-English explanation, one-click fix where safe (with preview, I3), "explain" link.

## UC7 — Attribute an unexpected Touch ID prompt

**Goal:** preserve the invariant "every touch maps to an action I just took."

1. User hits "What's asking?" (menu bar) while a prompt is on screen.
2. Vaultkit snapshots ssh/git processes with parent chains and live connections; renders the chain in human terms ("Terminal → zsh → git push to forge.rhost.rw" / "launched by an app you don't recognize").
3. Verdict guidance: *expected* (matches a command just run) vs. *investigate* (deny the prompt; offer the Doctor's deep scan).
4. Log the event locally so patterns are visible ("3 unexplained prompts this week").

## UC8 — Offboard an organization (P2's exit)

1. Eject + optionally **destroy** the vault (with explicit double confirmation), or export it to an encrypted archive handed to the client.
2. Remove config blocks (previewed diff), delete the enclave identity, remind about forge-side key deletion (deep link).
3. Produce a plain-English offboarding receipt: what was removed, what the user must still do in the browser.

## UC9 — Export / import a team recipe (P4)

- Export: org definitions *minus anything secret* (no keys — they're per-machine by design) as a JSON recipe.
- Import: wizard pre-filled from the recipe; each teammate still creates their own enclave keys and passphrases (I1 — keys are never shared).
- Team posture: each machine runs its own Doctor; results are for the user to share, not phoned home (no telemetry, ever).

## UC10 — Per-org private registry credentials

**Persona:** P1/P2 · **Goal:** a package-registry token (GitHub Packages, private npm,
GitLab registry) usable in exactly one org context, encrypted at rest, never ambient.

Some registries require a token even for read access — SSH keys don't apply. When an
install fails with a registry 401 inside an org folder, Vaultkit offers the contained
pattern:

1. Detect the failing registry from the error/lockfile; explain why a token is unavoidable.
2. Guide token creation on the right account with the **minimum scope** (e.g. classic PAT,
   `read:packages` only, 90-day expiry) — deep link, never handling the token itself.
3. Scaffold containment: a registry config file **inside the org's vault**
   (`.npmrc-<org>` with scope→registry mapping) activated only in that folder
   (`NPM_CONFIG_USERCONFIG` via the org's env layer). The user pastes the token into the
   vault file themselves.
4. Register the token in the org's **credential inventory**: the Doctor tracks expiry,
   verifies it stays scoped/contained, and the offboarding flow (UC8) lists it for
   revocation. At incident time, the inventory is the "revoke these first" list.

**Invariant note:** this is the one deliberate exception to "no durable tokens" — made
explicit, minimal-scope, vault-contained, and inventoried, instead of ambient in
`~/.npmrc` where every process can read it.

## UC11 — Clone through the app

**Persona:** all · **Goal:** cloning a repository can't put it in the wrong context.

From an org's card (mounted vaults only): paste an SSH clone URL. The app binds
URL → org key → vault destination by construction, checks the URL's host against
the **pinned known_hosts** (refusing unverified hosts with an explanation — no
trust-on-first-use after an incident), passes the org's `core.sshCommand`
explicitly (includeIf config isn't reliably applied *during* clone), and warns
that Touch ID will prompt. Cross-org misrouting is impossible through this path.

## Non-goals

- Not an antivirus, not an EDR — the Doctor checks *configuration*, not malware.
- No key escrow, no cloud sync, no account system, no telemetry.
- No custom crypto: all primitives are the OS's (Secure Enclave, APFS encryption, OpenSSH).
- Does not manage what happens *inside* repos (that's the forge's rulesets and the team's review process).
