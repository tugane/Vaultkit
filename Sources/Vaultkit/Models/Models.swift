import Foundation

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
    case unlocked    // keys cached but not mounted (e.g. TM snapshot) — NOT at rest
    case mounted     // volume unlocked and mounted at the org folder
    case misplaced   // mounted, but NOT at the org folder (e.g. Finder's /Volumes/<Name>)
}

/// One organization the user works for. This struct is a *view* of the real
/// configuration on disk (gitconfig includes, ssh keys, APFS volumes) — never
/// a competing source of truth. The Doctor re-derives it from the system.
struct Organization: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String                 // "wecreate"
    var displayName: String          // "WeCreate GmbH"
    var gitAuthorName: String        // "Amiel Tugane"
    var gitEmail: String             // "amiel.tugane@wecreate.world"
    var forge: ForgeKind
    var forgeHost: String            // "github.com", "forge.rhost.rw"
    var forgeSSHPort: Int?           // nil = 22; e.g. 2222 for built-in Gitea SSH
    var folderPath: String           // "~/work/wecreate"
    var keyLabel: String             // Secure Enclave identity label, "ssh-wecreate"
    var signingEnabled: Bool
    var vault: VaultState
    var sshCommand: String? = nil    // the org's core.sshCommand (drives clones)
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
