import Foundation
import TuganeDesign

/// Read-only drift detection (UC6). Every check derives from the system itself
/// (invariant I2). Each one below exists because the drift actually happened
/// during the manual setup this app is based on.
final class DoctorService: DoctorServing, @unchecked Sendable {
    private let runner: any SystemCommandRunning
    private let defaults: UserDefaults
    private let fm = FileManager.default

    init(runner: any SystemCommandRunning = ProcessRunner(), defaults: UserDefaults = .standard) {
        self.runner = runner
        self.defaults = defaults
    }
    private var home: String { fm.homeDirectoryForCurrentUser.path }

    func runAllChecks(orgs: [Organization]) async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        findings += guardChecks(orgs: orgs)
        findings += shadowChecks(orgs: orgs)
        findings += ambientCredentialChecks()
        findings += gitIdentityChecks(orgs: orgs)
        findings += await backupChecks(orgs: orgs)
        findings += await signatureChecks(orgs: orgs)
        findings += await systemPostureChecks()
        return findings.sorted { $0.severity > $1.severity }
    }

    // MARK: signature health
    //
    // Observed in the wild: the Secure Enclave provider can emit an SSHSIG that
    // does not verify, while SSH auth with the same key keeps working. The
    // commit looks signed, git reports "B", and nothing warns you, so check.

    private func signatureChecks(orgs: [Organization]) async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        for org in orgs where org.signingEnabled && org.vault == .mounted {
            let root = expand(org.folderPath)
            guard let repos = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for repo in repos {
                let path = "\(root)/\(repo)"
                guard fm.fileExists(atPath: "\(path)/.git") else { continue }
                guard let r = try? await runner.run(
                    "/usr/bin/git",
                    ["-C", path, "log", "--format=%h %G?", "-20"]
                ), r.status == 0 else { continue }

                let bad = r.stdout.split(separator: "\n").filter { line in
                    let flag = line.split(separator: " ").last.map(String.init) ?? ""
                    return flag == "B" || flag == "E"
                }
                guard !bad.isEmpty else { continue }
                findings.append(DoctorFinding(
                    checkName: "Unverifiable commit signatures",
                    severity: .warning,
                    detail: "\(plural(bad.count, "recent commit")) in \(repo) carry a signature that does not verify (\(bad.prefix(3).joined(separator: ", "))). Usually a Secure Enclave provider glitch rather than tampering, but pushing them shows red on the forge.",
                    remediation: "Re-sign the tip with: git -C \(path) commit --amend --no-edit",
                    autoFixable: false,
                    orgName: org.name
                ))
            }
        }
        return findings
    }

    // MARK: placeholder guards (a cancelled unlock once left one writable)

    private func guardChecks(orgs: [Organization]) -> [DoctorFinding] {
        orgs.compactMap { org in
            guard org.vault == .locked else { return nil }
            let path = expand(org.folderPath)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let perms = attrs[.posixPermissions] as? NSNumber,
                  perms.intValue != 0 else { return nil }
            return DoctorFinding(
                checkName: "Open guard on locked vault",
                severity: .warning,
                detail: "\(org.folderPath) is writable while the \(org.displayName) vault is locked. Anything created there lands on the unencrypted disk and is hidden when the vault mounts.",
                remediation: "chmod 000 the placeholder directory.",
                autoFixable: true,
                orgName: org.name
            )
        }
    }

    // MARK: shadowed files (an 'untitled folder' once got trapped this way)

    private func shadowChecks(orgs: [Organization]) -> [DoctorFinding] {
        orgs.compactMap { org in
            guard org.vault == .locked else { return nil }
            let path = expand(org.folderPath)
            // A closed guard (chmod 000) blocks listing even for the owner.
            // Briefly open read, list, and restore, or trapped plaintext behind
            // a properly-closed guard would be undetectable forever.
            var contents = try? fm.contentsOfDirectory(atPath: path)
            if contents == nil,
               let attrs = try? fm.attributesOfItem(atPath: path),
               let perms = attrs[.posixPermissions] as? NSNumber, perms.intValue == 0 {
                try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
                contents = try? fm.contentsOfDirectory(atPath: path)
                try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
            }
            // Finder's .DS_Store is not user data; flagging it as trapped
            // plaintext was a critical finding for a folder someone looked at.
            let trapped = (contents ?? []).filter { !DiskUtilVaultService.finderMetadata.contains($0) }
            guard !trapped.isEmpty else { return nil }
            return DoctorFinding(
                checkName: "Files trapped under a locked vault",
                severity: .critical,
                detail: "\(org.folderPath) contains \(trapped.count) item(s) on the plain disk. They are unencrypted, and mounting the vault will hide them (shadowing, not merging): \(trapped.prefix(3).joined(separator: ", ")).",
                remediation: "Move the items into the vault (mounted) or delete them, then re-close the guard.",
                autoFixable: false
            )
        }
    }

    // MARK: ambient credentials (a gh login once landed in the default dir)

    private func ambientCredentialChecks() -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        if fm.fileExists(atPath: home + "/.config/gh/hosts.yml") {
            findings.append(DoctorFinding(
                checkName: "Ambient GitHub CLI login",
                severity: .critical,
                detail: "~/.config/gh/hosts.yml exists. A gh login is active outside any organization folder, usable by every process on the machine.",
                remediation: "gh auth logout in the default context (run it outside any org folder), or delete the stray hosts.yml.",
                autoFixable: false
            ))
        }
        if fm.fileExists(atPath: home + "/.npmrc") {
            let content = (try? String(contentsOfFile: home + "/.npmrc", encoding: .utf8)) ?? ""
            if content.contains("_authToken") {
                findings.append(DoctorFinding(
                    checkName: "Ambient npm registry token",
                    severity: .critical,
                    detail: "~/.npmrc contains an _authToken readable by every process. Registry tokens should live in a vault-scoped userconfig (UC10).",
                    remediation: "Move the token into an org's .npmrc-<org> inside its vault, activated via NPM_CONFIG_USERCONFIG.",
                    autoFixable: false
                ))
            }
        }
        return findings
    }

    // MARK: git identity hygiene

    private func gitIdentityChecks(orgs: [Organization]) -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        let gitconfig = (try? String(contentsOfFile: home + "/.gitconfig", encoding: .utf8)) ?? ""
        if !gitconfig.contains("useConfigOnly = true") {
            findings.append(DoctorFinding(
                checkName: "Git identity guessing enabled",
                severity: .warning,
                detail: "user.useConfigOnly is not set. Git will invent an identity (user@hostname) in folders with no explicit config instead of refusing.",
                remediation: "git config --global user.useConfigOnly true",
                autoFixable: true
            ))
        }
        for org in orgs where !org.signingEnabled {
            findings.append(DoctorFinding(
                checkName: "Commit signing off for \(org.displayName)",
                severity: .warning,
                detail: "Commits in \(org.folderPath) are unsigned. A tampered or amended commit is indistinguishable from yours.",
                remediation: "Enable SSH signing with the org's enclave key (UC3).",
                autoFixable: false
            ))
        }
        return findings
    }

    // MARK: backup exposure
    //
    // Inclusion alone is not the risk. Time Machine copies files, so a mounted
    // vault is copied as plaintext, and that matters only when the destination
    // is unencrypted. This check used to warn on inclusion alone, which on a
    // machine whose backup disk has a password docked 10 points per mounted
    // vault for a risk already closed, and taught the reader to skip it.
    //
    // A backup disk is usually unplugged, and its encryption is only readable
    // while it is connected, so what is learned then is remembered. A backup
    // can only be written while the disk is connected, which is exactly when
    // the check gets to look, so the unknown case never hides a live copy.

    struct BackupDestination: Equatable {
        var id: String
        var name: String
        var mountPoint: String?
    }

    /// `tmutil destinationinfo`: blocks separated by rules of "=", each a list
    /// of "Key : value" lines. "Mount Point" appears only while connected.
    static func parseDestinations(_ text: String) -> [BackupDestination] {
        var out: [BackupDestination] = []
        var fields: [String: String] = [:]
        func flush() {
            if let id = fields["ID"], !id.isEmpty {
                out.append(BackupDestination(id: id, name: fields["Name"] ?? "the backup disk",
                                             mountPoint: fields["Mount Point"]))
            }
            fields = [:]
        }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("===") { flush(); continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        flush()
        return out
    }

    private func encryptionKey(_ id: String) -> String { "vk.backupEncrypted.\(id)" }

    /// What a connected disk says about itself, or nil when diskutil has no
    /// answer (a network share, say), so a guess is never recorded as fact.
    private func isEncrypted(mountPoint: String) async -> Bool? {
        guard let r = try? await runner.run("/usr/sbin/diskutil", ["info", mountPoint]),
              r.status == 0 else { return nil }
        guard let line = r.stdout.split(separator: "\n").first(where: { $0.contains("FileVault:") })
        else { return nil }
        return line.contains("Yes")
    }

    func backupChecks(orgs: [Organization]) async -> [DoctorFinding] {
        guard let dest = try? await runner.run("/usr/bin/tmutil", ["destinationinfo"]),
              dest.status == 0, !dest.stdout.contains("No destinations") else { return [] }
        let destinations = Self.parseDestinations(dest.stdout)
        guard !destinations.isEmpty else { return [] }

        var encrypted: [String: Bool] = [:]
        for d in destinations {
            if let mp = d.mountPoint, let e = await isEncrypted(mountPoint: mp) {
                defaults.set(e, forKey: encryptionKey(d.id))
            }
            encrypted[d.id] = defaults.object(forKey: encryptionKey(d.id)) as? Bool
        }
        let plain = destinations.filter { encrypted[$0.id] == false }
        let unknown = destinations.filter { encrypted[$0.id] == nil }
        if plain.isEmpty && unknown.isEmpty { return [] }   // every copy is ciphertext

        // Only check mounted vaults: sticky exclusion xattrs live on the volume
        // root and are invisible on the locked placeholder inode: checking
        // there produced false "included" findings. Mounted is also exactly
        // when backup exposure actually happens.
        var included: [Organization] = []
        for org in orgs where org.vault == .mounted {
            guard let r = try? await runner.run("/usr/bin/tmutil", ["isexcluded", expand(org.folderPath)]),
                  r.stdout.contains("[Included]") else { continue }
            included.append(org)
        }
        guard !included.isEmpty else { return [] }

        if !plain.isEmpty {
            let names = plain.map(\.name).joined(separator: ", ")
            return included.map { org in
                DoctorFinding(
                    checkName: "Vault backed up in plaintext",
                    severity: .warning,
                    detail: "\(org.folderPath) is included in backups to \(names), which is not encrypted. Time Machine copies files, so while the vault is mounted its plaintext, and any tokens inside, is copied there and kept in every snapshot.",
                    remediation: "Turn on Encrypt Backup for \(names) in Time Machine settings, or: sudo tmutil addexclusion -p \(expand(org.folderPath))",
                    autoFixable: false,
                    orgName: org.name
                )
            }
        }
        // One note about the disk, not one per vault: the unknown is the disk.
        let names = unknown.map(\.name).joined(separator: ", ")
        return [DoctorFinding(
            checkName: "Backup encryption not yet checked",
            severity: .info,
            detail: "\(plural(included.count, "mounted vault")) \(included.count == 1 ? "is" : "are") included in backups to \(names), which Vaultkit has not yet seen connected, so it cannot tell whether the disk is encrypted. If it has a backup password, it is. Connect it once and this goes away, or turns into a warning if it is not.",
            remediation: nil,
            autoFixable: false
        )]
    }

    // MARK: system posture (reported neutrally: the user decides)

    private func systemPostureChecks() async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        if let r = try? await runner.run("/usr/bin/fdesetup", ["status"]),
           r.stdout.contains("FileVault is Off") {
            findings.append(DoctorFinding(
                checkName: "System disk unencrypted",
                severity: .info,
                detail: "FileVault is off. Org vaults are the only at-rest encryption on this Mac. Everything outside them is readable with physical disk access.",
                remediation: "System Settings → Privacy & Security → FileVault (optional; your call).",
                autoFixable: false
            ))
        }
        return findings
    }

    // MARK: fixes (only the provably-safe ones are automated)

    func applyFix(for finding: DoctorFinding, orgs: [Organization]) async {
        switch finding.checkName {
        case "Open guard on locked vault":
            // Scope strictly to the finding's org. A blanket chmod would race
            // a concurrent mount that legitimately opened another org's guard.
            // This used to chmod on the strength of the cached vault state
            // alone; if that state was stale and the volume had mounted, the
            // chmod rewrote the volume root. Now it goes through the same
            // filesystem checks as the automatic repair. A press is explicit,
            // so it skips the grace period and the emptiness test.
            if let org = orgs.first(where: { $0.name == finding.orgName }), org.vault == .locked {
                _ = DiskUtilVaultService.recloseGuard(at: expand(org.folderPath), grace: 0, requireEmpty: false)
            }
        case "Git identity guessing enabled":
            _ = try? await runner.run("/usr/bin/git", ["config", "--global", "user.useConfigOnly", "true"])
        default:
            break
        }
    }

    private func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
