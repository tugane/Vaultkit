import Foundation

// MARK: - System boundary
//
// Every interaction Vaultkit has with the system goes through these protocols.
// The real implementations shell out to the same battle-tested tools an expert
// would use by hand (sc_auth, ssh-keygen, diskutil, git, ssh). Vaultkit adds
// orchestration, preview, and verification, never reimplements crypto.
// Protocol-first so every flow is testable against fakes.

/// Runs a system command and captures its output. The ONLY place Process is used.
/// `stdin` is used exclusively for `-stdinpassphrase` (see the I1 note in data-flow.md).
protocol SystemCommandRunning: Sendable {
    func run(_ tool: String, _ arguments: [String], stdin: String?, cwd: String?) async throws -> CommandResult
}

extension SystemCommandRunning {
    func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult {
        try await run(tool, arguments, stdin: nil, cwd: nil)
    }
    func run(_ tool: String, _ arguments: [String], stdin: String?) async throws -> CommandResult {
        try await run(tool, arguments, stdin: stdin, cwd: nil)
    }
}

/// Secure Enclave SSH identities via `sc_auth` + `ssh-keygen -K`.
protocol EnclaveKeyServing {
    func listIdentities() async throws -> [String]                    // labels
    func createIdentity(label: String) async throws                   // -k p-256-ne -t bio
    func exportReferenceKey(label: String, to path: String) async throws
    func publicKey(label: String) async throws -> String
}

/// Surgical reads/patches of ~/.gitconfig and per-org include files.
/// NEVER rewrites content it did not create; every mutation returns a preview
/// diff that the UI must show before applying.
protocol GitConfigServing {
    func currentIncludes() async throws -> [(pathPattern: String, file: String)]
    func previewAddOrganization(_ org: Organization) async throws -> String   // unified diff
    func applyAddOrganization(_ org: Organization) async throws
    func previewEnableSigning(_ org: Organization) async throws -> String
    func applyEnableSigning(_ org: Organization) async throws
}

/// Encrypted APFS vault lifecycle via `diskutil apfs`.
/// Passphrases are entered in diskutil's own interactive prompt or the system
/// dialog. They never pass through Vaultkit.
protocol VaultServing {
    func state(of org: Organization) async throws -> VaultState
    func createVault(for org: Organization) async throws              // addVolume -passprompt
    /// Passphrase transits app memory once, piped to -stdinpassphrase, never
    /// stored (documented I1 deviation. See data-flow.md).
    func mount(_ org: Organization, passphrase: String) async throws
    func eject(_ org: Organization) async throws                      // lockVolume w/ dissenter handling
    func dissenters(for org: Organization) async throws -> [String]   // "zsh (pid 6223)"
}

/// Known-host pinning with published-fingerprint verification where available.
protocol HostPinServing {
    func scanFingerprints(host: String, port: Int) async throws -> [String]
    func publishedFingerprints(for forge: ForgeKind) -> [String]?     // nil for custom forges
    func pin(host: String, port: Int) async throws
}

/// The Doctor: re-derives the real state of the machine from config files and
/// system state, and reports drift. Read-only by construction.
protocol DoctorServing {
    func runAllChecks(orgs: [Organization]) async -> [DoctorFinding]
}
