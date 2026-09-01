# Vaultkit — Data Flow & Architecture

## Layers

```mermaid
flowchart TB
    subgraph UI["UI layer (SwiftUI)"]
        WIZ[Onboarding wizard]
        DASH[Dashboard]
        VLT[Vaults panel + MenuBarExtra]
        DOC[Doctor panel]
        ASK["What's asking?"]
    end

    subgraph CORE["Core engine (services, protocol-first)"]
        GCS[GitConfigServing<br/>surgical config patching]
        EKS[EnclaveKeyServing<br/>sc_auth / ssh-keygen]
        VS[VaultServing<br/>diskutil apfs]
        HPS[HostPinServing<br/>keyscan + published fingerprints]
        DS[DoctorServing<br/>read-only derivation]
        SCR[SystemCommandRunning<br/>the ONLY Process boundary]
    end

    subgraph SYS["System (macOS)"]
        SE[(Secure Enclave)]
        FILES[("~/.gitconfig, ~/.gitconfig-*<br/>~/.ssh/config, known_hosts,<br/>reference keys, allowed_signers")]
        APFS[(Encrypted APFS volumes)]
        TID[[Touch ID / system dialogs]]
    end

    subgraph EXT["External (user-driven only)"]
        FORGE[Forges: GitHub / GitLab /<br/>Gitea / custom]
    end

    UI --> CORE
    GCS --> FILES
    EKS --> SCR
    VS --> SCR
    HPS --> SCR
    DS --> FILES
    DS --> SCR
    SCR --> SE
    SCR --> APFS
    SE -.every use.-> TID
    APFS -.unlock passphrase.-> TID
    SCR -->|ssh auth test, keyscan| FORGE
    UI -->|deep links: key registration pages| FORGE
```

**Rules encoded in the layering:**

- The UI never touches the system; it calls services. Services never render UI.
- `SystemCommandRunning` is the single choke point for subprocess execution —
  auditable, mockable, and the natural place for the "preview every command" hook.
- Nothing in any layer stores secrets. The two dotted edges are where secrets
  exist — inside Apple's dialogs, invisible to the app (invariant I1).

## Sources of truth

| Data | Lives in | Vaultkit's copy |
|---|---|---|
| Git identity & routing | `~/.gitconfig` + `~/.gitconfig-<org>` | derived, disposable |
| SSH key handles | Secure Enclave + `~/.ssh/id_*` reference files | derived (labels only) |
| Host pins | `~/.ssh/known_hosts` | derived |
| Vault state | APFS container (`diskutil`) | derived, polled |
| Org registry (names, forge hosts, folder paths) | `~/Library/Application Support/Vaultkit/orgs.json` | **owned** — the only file Vaultkit owns, and it contains no secrets |

If `orgs.json` is deleted, the Doctor can reconstruct organizations by scanning
the gitconfig includes — the app degrades gracefully (invariant I2).

## Flow 1 — Add organization (UC1/UC2)

```mermaid
sequenceDiagram
    actor U as User
    participant W as Wizard (UI)
    participant E as EnclaveKeyServing
    participant H as HostPinServing
    participant G as GitConfigServing
    participant S as System (sc_auth/ssh/git)
    participant F as Forge (browser)

    U->>W: org details (name, email, forge, host)
    W->>H: probe forge (API kind, SSH port, fingerprints)
    H->>S: ssh-keyscan, https probe (read-only)
    S-->>W: fingerprints + port quirks (e.g. :2222)
    W->>U: show fingerprints + verification path
    U->>W: confirm verified (or run cross-check)
    W->>H: pin host keys
    W->>E: create enclave identity
    E->>S: sc_auth create-ctk-identity -t bio
    S-->>U: Touch ID prompt (system)
    W->>E: export reference key → ~/.ssh
    W->>G: preview config diff
    G-->>U: exact diff shown
    U->>W: approve
    W->>G: apply (surgical patch)
    W->>U: public key + deep link to forge settings
    U->>F: paste key, delete stale keys
    W->>S: ssh -T auth test (retry loop)
    S-->>W: "Hi username!" 
    W->>U: verified ✓ (greeting shown as proof)
```

## Flow 2 — Vault lifecycle (UC4/UC5)

```mermaid
sequenceDiagram
    actor U as User
    participant M as MenuBar / Vaults UI
    participant V as VaultServing
    participant S as diskutil
    participant OS as macOS dialog

    U->>M: Mount rmsoft
    M->>V: mount(org)
    V->>V: open placeholder guard (chmod 700)
    V->>S: apfs unlockVolume -mountpoint ~/work/rmsoft
    S->>OS: passphrase prompt (system-owned)
    U->>OS: passphrase (never seen by app)
    alt unlock succeeds
        S-->>V: mounted
        V-->>M: state = mounted (exposed)
    else cancelled / failed
        V->>V: re-close guard (chmod 000)  %% fail closed, I4
        V-->>M: state = locked
    end

    U->>M: Eject rmsoft
    M->>V: eject(org)
    V->>S: apfs lockVolume
    alt dissenters (user-level)
        V->>V: lsof → name holders
        V-->>U: "Terminal tab in ~/work/rmsoft" — close & retry
    else dissenters (root-level: Spotlight/AV)
        V->>V: empty lsof + lock failure ⇒ infer root holder
        V->>S: retry with backoff, fall back to unmount
    end
    S-->>V: locked
    V->>V: close guard (chmod 000)
    V-->>M: state = locked (at rest)
```

## Flow 3 — Doctor (UC6)

```mermaid
flowchart LR
    T[Trigger: manual / on-launch / daily] --> R[Read-only sweep]
    R --> C1[gitconfig parse:<br/>includes, identities, signing]
    R --> C2[ssh: config, known_hosts<br/>vs pinned fingerprints]
    R --> C3[diskutil: vault states,<br/>guard permissions]
    R --> C4[credential scan: default-dir<br/>CLI logins, keyring leftovers]
    R --> C5[shadow scan: files trapped<br/>under unmounted placeholders]
    C1 & C2 & C3 & C4 & C5 --> A[Findings: severity + explanation<br/>+ previewed one-click fix]
    A --> U[User approves fixes individually]
    U --> X[Apply via services<br/>never silently]
```

## Trust boundaries & privilege inventory

| Operation | Tool | Privilege | Secret exposure |
|---|---|---|---|
| Create/list/delete enclave identity | `sc_auth` | user | none — key born in enclave |
| Export reference key | `ssh-keygen -K` | user | none — handle file, useless without enclave+touch |
| Read/patch git & ssh config | direct file IO | user | none |
| Create encrypted volume | `diskutil apfs addVolume -passprompt` | user (Owners enabled) | passphrase in system prompt only |
| Mount/eject vault | `diskutil apfs unlock/lockVolume` | user | same |
| Auth verification | `ssh -T` | user | signature via enclave + touch |
| Host scan / forge probe | `ssh-keyscan`, HTTPS GET | user | none (public data) |
| Prompt attribution | `ps`, `lsof` | user (root holders inferred, not seen) | none |

### Passphrase entry paths (honest note on I1)

`diskutil` has no GUI prompt when driven by an app, so v0.x mounts use an app-rendered
`SecureField` piped to `diskutil apfs unlockVolume -stdinpassphrase`: the passphrase
transits app memory once, is never persisted or logged, and the buffer is released
immediately. This is a documented deviation from the "system dialogs only" ideal;
the roadmap is to move to a DiskArbitration-based unlock where macOS owns the dialog.
Volume *creation* stays fully I1-clean: the wizard hands that step to the user's
terminal (`-passprompt`), exactly like the manual flow.

**No component runs as root.** No privileged helper is installed. The app is
sandboxed-hostile territory (it must touch `~/.ssh` and run `diskutil`), so it
ships **unsandboxed but hardened-runtime, signed and notarized** — and open
source, because its audience will (rightly) read the code before trusting it.

## Failure modes the design must absorb

1. **Cancelled system prompts** at any step → fail closed, state machine returns to the last safe state (I4).
2. **Touch ID unavailable** (clamshell, external display) → detect via `AppleClamshellState` preflight, wait for change, resume.
3. **Root-level vault dissenters** (indexing, AV) → invisible to user-level `lsof`; infer from empty-holder + lock failure, retry with backoff.
4. **Hand-edited configs** → the parser must preserve unknown content byte-for-byte; if a file can't be parsed confidently, Vaultkit refuses to patch and explains, never guesses.
5. **Forge quirks** → SSH on non-standard ports (Gitea built-in server), GitLab's signing-key re-add restriction, GitHub SSO authorize buttons: encoded per-forge, verified by the live auth test rather than assumed.
6. **Deleted app state** → orgs.json is reconstructable from the system (I2).
7. **Backup software interaction** → Time Machine snapshots can hold a vault
   *unlocked after unmount* (plain mount then needs no passphrase — handle the
   `-69589 not locked` path), and an **included vault path copies plaintext to
   the backup destination** while mounted. Worse: **`lockVolume` reports
   success while a mounted snapshot still references the keys** — the volume
   silently stays unlocked, so every lock must be verified afterwards (evict
   snapshot mounts, relock, re-check) before claiming "at rest". The Doctor
   must check: vault paths excluded from backups, or the destination encrypted.
