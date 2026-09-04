import Foundation
import TuganeDesign

/// Read-only drift detection (UC6). Every check derives from the system itself
/// (invariant I2). Each one below exists because the drift actually happened
/// during the manual setup this app is based on.
final class DoctorService: DoctorServing, @unchecked Sendable {
    private let runner: any SystemCommandRunning
    private let fm = FileManager.default

    init(runner: any SystemCommandRunning = ProcessRunner()) {
        self.runner = runner
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
            guard let contents, !contents.isEmpty else { return nil }
            return DoctorFinding(
                checkName: "Files trapped under a locked vault",
                severity: .critical,
                detail: "\(org.folderPath) contains \(contents.count) item(s) on the plain disk. They are unencrypted, and mounting the vault will hide them (shadowing, not merging): \(contents.prefix(3).joined(separator: ", ")).",
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

    // MARK: backup exposure (Time Machine once held a vault unlocked
    // and its destination includes vault paths)

    private func backupChecks(orgs: [Organization]) async -> [DoctorFinding] {
        guard let dest = try? await runner.run("/usr/bin/tmutil", ["destinationinfo"]),
              dest.status == 0, !dest.stdout.contains("No destinations") else { return [] }
        var findings: [DoctorFinding] = []
        // Only check mounted vaults: sticky exclusion xattrs live on the volume
        // root and are invisible on the locked placeholder inode: checking
        // there produced false "included" findings. Mounted is also exactly
        // when backup exposure actually happens.
        for org in orgs where org.vault == .mounted {
            let path = expand(org.folderPath)
            guard let r = try? await runner.run("/usr/bin/tmutil", ["isexcluded", path]),
                  r.stdout.contains("[Included]") else { continue }
            findings.append(DoctorFinding(
                checkName: "Vault included in Time Machine",
                severity: .warning,
                detail: "\(org.folderPath) is included in backups. While mounted, its plaintext (and any tokens inside) is copied to the backup destination, and snapshots can hold the volume unlocked.",
                remediation: "sudo tmutil addexclusion -p \(path), or encrypt the backup destination.",
                autoFixable: false
            ))
        }
        return findings
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
            if let org = orgs.first(where: { $0.name == finding.orgName }), org.vault == .locked {
                try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: expand(org.folderPath))
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
