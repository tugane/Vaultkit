import Foundation

/// Single source of truth for the version shown in the UI and bug reports.
enum VaultkitVersion {
    static let current = "0.1.0"
}

/// A forge is wherever an organization hosts its git repositories.
enum ForgeKind: String, Codable, CaseIterable, Identifiable {
    case github
    case gitlab
    case gitea      // includes Forgejo and rebranded instances
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .gitea: "Gitea / Forgejo"
        case .custom: "Custom (SSH only)"
        }
    }
}

/// The lifecycle state of an organization's encrypted vault.
enum VaultState: String, Codable {
    case none        // org folder lives on the plain disk (no vault)
    case locked      // volume exists, keys dropped (data at rest)
    case unlocked    // keys cached but not mounted (e.g. TM snapshot): NOT at rest
    case mounted     // volume unlocked and mounted at the org folder
    case misplaced   // mounted, but NOT at the org folder (e.g. Finder's /Volumes/<Name>)
}

/// One organization the user works for. This struct is a *view* of the real
/// configuration on disk (gitconfig includes, ssh keys, APFS volumes): never
/// a competing source of truth. The Doctor re-derives it from the system.
struct Organization: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String                 // "acme"
    var displayName: String          // "Acme GmbH"
    var gitAuthorName: String        // "Ada Lovelace"
    var gitEmail: String             // "you@example.com"
    var forge: ForgeKind
    var forgeHost: String            // "github.com", "forge.rhost.rw"
    var forgeSSHPort: Int?           // nil = 22; e.g. 2222 for built-in Gitea SSH
    var folderPath: String           // "~/work/acme"
    var keyLabel: String             // Secure Enclave identity label, "ssh-acme"
    var signingEnabled: Bool
    var vault: VaultState
    var sshCommand: String? = nil    // the org's core.sshCommand (drives clones)

    /// Reference-key file Vaultkit writes into ~/.ssh for orgs it creates.
    var keyFileName: String { "id_sk_\(name)" }
}

/// A single health check the Doctor performs, with its outcome.
struct DoctorFinding: Identifiable {
    enum Severity: Comparable { case info, warning, critical }

    var id: UUID = UUID()
    var checkName: String            // "Ambient credential outside org folders"
    var severity: Severity
    var detail: String               // human explanation of what was found
    var remediation: String?         // what the one-click fix would do (nil = manual)
    var autoFixable: Bool
    var orgName: String? = nil       // the org this finding targets (scopes auto-fixes)
}

/// One indicator match from the Scanner (UC12). Findings are keyed by file so
/// an incremental pass can replace exactly the ones it re-evaluated.
struct ScanFinding: Identifiable, Hashable {
    /// What the Scanner can do about this hit without a human.
    enum Fix: Hashable {
        case clean                   // truncate an appended loader, keep the legitimate content
        case quarantine              // move the whole file or directory out of the tree
        case dropDependency(String)  // remove one package from package.json
        case dropGitignoreLine       // remove the injected "config.bat" line
        case manual                  // nothing safe to automate
    }

    var id: UUID = UUID()
    var orgName: String
    var repo: String                 // nearest enclosing git repository
    var path: String                 // relative to the org folder
    var absolutePath: String
    var indicator: String            // "PolinRider loader: original variant"
    var severity: DoctorFinding.Severity
    var evidence: String             // the marker matched: never payload bytes
    var remediation: String
    var fix: Fix = .manual
}

/// One pass of the Scanner, as kept in the history.
struct ScanEvent: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var duration: TimeInterval
    var mode: String                 // "full", "changed files", "deep"
    var orgs: [String]
    var repos: Int
    var files: Int
    var hits: Int
}

/// Something the Scanner did, or could not do: about a finding.
struct ActionEvent: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case cleaned, quarantined, restored, purged, manual }
    var id: UUID = UUID()
    var date: Date
    var kind: Kind
    var orgName: String
    var path: String                 // relative to the org folder
    var indicator: String
    var detail: String
    var quarantineID: String? = nil
}

/// A file the Scanner moved out of harm's way. It lives inside the org's own
/// vault, so it stays encrypted at rest and never leaves the compartment, with
/// a neutralized name so nothing can import it by accident.
struct QuarantineItem: Identifiable, Codable, Hashable {
    var id: String                   // "20260904-171203-3f2a"
    var orgName: String
    var originalPath: String         // relative to the org folder
    var indicator: String
    var evidence: String
    var date: Date
    var kind: ActionEvent.Kind       // .cleaned keeps the original here; .quarantined moved it whole
    var sha256: String               // of the original bytes ("" for a directory)
    var bytes: Int
}

struct ScannerHistory: Codable {
    var scans: [ScanEvent] = []
    var actions: [ActionEvent] = []
}

/// What an organization removal did, and what it could not do for you.
struct RemovalReceipt: Identifiable {
    var id: UUID = UUID()
    var org: String
    var done: [String]
    var todo: [String]
}
