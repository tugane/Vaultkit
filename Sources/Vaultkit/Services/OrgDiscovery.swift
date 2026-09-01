import Foundation

/// Derives the organization list from the system's own config (invariant I2):
/// `~/.gitconfig` includeIf blocks are the registry — Vaultkit's own state file
/// is only ever a cache on top of this.
struct OrgDiscovery {

    static func discover() -> [Organization] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let gitconfig = try? String(contentsOfFile: home + "/.gitconfig", encoding: .utf8) else {
            return []
        }

        // Match: [includeIf "gitdir:~/work/<name>/"]
        var orgs: [Organization] = []
        // Any non-slash folder name — git accepts more than lowercase ASCII.
        let pattern = #/includeIf "gitdir:~/work/([^/"]+)/"/#
        for match in gitconfig.matches(of: pattern) {
            let name = String(match.1)
            let perOrg = (try? String(contentsOfFile: home + "/.gitconfig-\(name)", encoding: .utf8)) ?? ""

            orgs.append(Organization(
                name: name,
                displayName: name.capitalized,
                gitAuthorName: firstValue(of: "name", in: perOrg) ?? "",
                gitEmail: firstValue(of: "email", in: perOrg) ?? "",
                forge: .custom,                      // forge details come later (wizard-owned)
                forgeHost: "",
                forgeSSHPort: nil,
                folderPath: "~/work/\(name)",
                keyLabel: "ssh-\(name)",
                signingEnabled: perOrg.contains("gpgsign = true"),
                vault: .none,                        // filled in by VaultServing
                sshCommand: firstValue(of: "sshCommand", in: perOrg)
            ))
        }
        return orgs
    }

    private static func firstValue(of key: String, in config: String) -> String? {
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) =") {
                return trimmed.dropFirst(key.count + 2).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
