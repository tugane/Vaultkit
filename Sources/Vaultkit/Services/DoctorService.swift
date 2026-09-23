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
    //
    // git collapses two unrelated events into that one letter and they want
    // opposite responses. A provider that emitted no signature bytes is a
    // signing failure over intact content. A complete signature that does not
    // match its commit is what an altered commit looks like. Reported as one
    // finding, the second reads as routine noise, so they are separated here
    // by looking inside the signature the commit actually carries.
    //
    // Neither is auto-fixable and neither remediation names a command that
    // rewrites history. Re-signing replaces the failing signature with a valid
    // one over whatever the content is now, destroying the only evidence this
    // check exists to surface; and commit rewriting is itself an attacker
    // technique Vaultkit detects elsewhere (ScannerService's propagation rule),
    // so it has no place in the app's own advice.

    /// Why a commit that git reports as "B" failed to verify.
    enum SignatureFault: Hashable {
        case emptySignature   // an SSHSIG envelope with no signature bytes in it
        case mismatch         // a complete signature, not over this commit
        case unclassified     // not an SSHSIG this can read (a PGP block, say)
    }

    private func signatureChecks(orgs: [Organization]) async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        for org in orgs where org.signingEnabled && org.vault == .mounted {
            let root = expand(org.folderPath)
            guard let repos = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for repo in repos.sorted() where fm.fileExists(atPath: "\(root)/\(repo)/.git") {
                findings += await signatureFindings(repo: repo, path: "\(root)/\(repo)", org: org)
            }
        }
        return findings
    }

    func signatureFindings(repo: String, path: String, org: Organization) async -> [DoctorFinding] {
        guard let log = try? await runner.run(
            "/usr/bin/git",
            ["-C", path, "log", "--format=%H %G?", "-20"]
        ), log.status == 0 else { return [] }

        var faulted: [SignatureFault: [String]] = [:]
        var uncheckable: [String] = []

        for line in log.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hash = String(parts[0])
            let short = String(hash.prefix(7))
            switch parts[1] {
            case "B":
                // Ask the object itself. The letter alone cannot tell a
                // provider that signed nothing from a signature over other
                // content, and that difference decides the severity.
                guard let raw = try? await runner.run(
                    "/usr/bin/git", ["-C", path, "cat-file", "commit", hash]
                ), raw.status == 0, let block = Self.signatureBlock(inRawCommit: raw.stdout) else {
                    faulted[.unclassified, default: []].append(short)
                    continue
                }
                faulted[Self.fault(inSignatureBlock: block), default: []].append(short)
            case "E":
                uncheckable.append(short)
            default:
                continue
            }
        }

        var findings: [DoctorFinding] = []

        if let empty = faulted[.emptySignature] {
            findings.append(DoctorFinding(
                checkName: "Commits signed with an empty signature",
                severity: .warning,
                detail: "\(plural(empty.count, "recent commit")) in \(repo) (\(Self.list(empty))) carry an SSHSIG with no signature bytes inside it. The Secure Enclave provider wrote the envelope and then signed nothing, so the commit looks signed and verifies as bad. The content is intact: this is a signing failure, not an altered commit.",
                remediation: "Nothing to repair in place. They stay unverified on the forge, and Vaultkit will not re-sign them: rewriting a commit to repair its signature is indistinguishable from the tampering this check exists to catch.",
                autoFixable: false,
                orgName: org.name))
        }

        if let mismatch = faulted[.mismatch] {
            findings.append(DoctorFinding(
                checkName: "Commit signatures that do not match their commit",
                severity: .critical,
                detail: "\(plural(mismatch.count, "recent commit")) in \(repo) (\(Self.list(mismatch))) carry a complete signature that does not verify against the commit it is attached to. That is what a commit altered after it was signed looks like, and what a signature lifted from another commit looks like.",
                remediation: "Leave the history as it is: the mismatch is the evidence, and a rewrite erases it. Read the commit with git show, check the reflog for a rewrite you did not perform, and treat the key as suspect until this is explained.",
                autoFixable: false,
                orgName: org.name))
        }

        if let unreadable = faulted[.unclassified] {
            findings.append(DoctorFinding(
                checkName: "Unreadable commit signatures",
                severity: .warning,
                detail: "\(plural(unreadable.count, "recent commit")) in \(repo) (\(Self.list(unreadable))) fail verification carrying a signature Vaultkit cannot read, so it cannot say whether the signer failed or the commit changed. A PGP-signed commit in an SSH-signing organization reads this way.",
                remediation: "Find out what signed them: git log --show-signature -1 <commit>.",
                autoFixable: false,
                orgName: org.name))
        }

        if !uncheckable.isEmpty {
            findings.append(DoctorFinding(
                checkName: "Commit signatures git cannot check",
                severity: .warning,
                detail: "\(plural(uncheckable.count, "recent commit")) in \(repo) (\(Self.list(uncheckable))) are signed, but git has no key to check them against. Signing that is never verified detects nothing.",
                remediation: "Add \(org.keyLabel)'s public key to the file named by gpg.ssh.allowedSignersFile.",
                autoFixable: false,
                orgName: org.name))
        }

        return findings
    }

    /// Commit hashes for a detail line: enough to go and look, not a wall.
    static func list(_ hashes: [String]) -> String {
        let shown = hashes.prefix(3).joined(separator: ", ")
        return hashes.count > 3 ? "\(shown) and \(hashes.count - 3) more" : shown
    }

    /// The signature header of a raw commit object: a `gpgsig` line whose
    /// continuations are indented one space, ending at the first line that is
    /// not. Returns the armored block with that indent removed.
    static func signatureBlock(inRawCommit raw: String) -> String? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("gpgsig") }),
              let space = lines[start].firstIndex(of: " ") else { return nil }

        var block = [String(lines[start][lines[start].index(after: space)...])]
        var i = start + 1
        while i < lines.count, lines[i].hasPrefix(" ") {
            block.append(String(lines[i].dropFirst()))
            i += 1
        }
        return block.joined(separator: "\n")
    }

    /// Reads the u32-length-prefixed strings SSHSIG is built from.
    private struct SSHReader {
        private let data: Data
        private var cursor = 0
        init(_ data: Data) { self.data = Data(data) }   // re-base: slices keep their origin's indices

        mutating func string() -> Data? {
            guard cursor + 4 <= data.count else { return nil }
            let length = data[cursor..<cursor + 4].reduce(0) { $0 << 8 | Int($1) }
            let start = cursor + 4
            guard start + length <= data.count else { return nil }
            cursor = start + length
            return Data(data[start..<start + length])
        }
    }

    /// Classify a failing signature (PROTOCOL.sshsig): a "SSHSIG" magic, a u32
    /// version, then five strings, the last holding an algorithm name and the
    /// signature bytes proper. A provider that fails part way still emits a
    /// well-formed envelope, so the emptiness is only visible this deep: the
    /// case that prompted this had eight zero bytes where a P-256 (r, s) pair
    /// of about seventy belongs.
    static func fault(inSignatureBlock block: String) -> SignatureFault {
        guard block.contains("BEGIN SSH SIGNATURE") else { return .unclassified }
        let body = block.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let blob = Data(base64Encoded: body), blob.count > 10,
              Data(blob.prefix(6)) == Data("SSHSIG".utf8) else { return .unclassified }

        var envelope = SSHReader(blob.dropFirst(10))          // past magic + version
        for _ in 0..<4 {                                      // publickey, namespace, reserved, hash
            guard envelope.string() != nil else { return .unclassified }
        }
        guard let signature = envelope.string() else { return .unclassified }

        var inner = SSHReader(signature)
        guard inner.string() != nil, let bytes = inner.string() else { return .unclassified }

        // A real signature is a pair of large integers: 64 bytes for ed25519,
        // about 70 for ecdsa, 256 for rsa. Nothing legitimate is this small.
        let signedNothing = bytes.count < 16 || bytes.allSatisfy { $0 == 0 }
        return signedNothing ? .emptySignature : .mismatch
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
