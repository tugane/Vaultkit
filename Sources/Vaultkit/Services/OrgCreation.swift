import Foundation

enum OrgCreationError: LocalizedError {
    case nameTaken(String)
    case invalidName
    case noContainer
    case step(String, String)   // step label, detail

    var errorDescription: String? {
        switch self {
        case .nameTaken(let n): "An organization or volume named \"\(n)\" already exists."
        case .invalidName: "Use lowercase letters, digits and dashes for the folder name (e.g. \"acme\")."
        case .noContainer: "Could not identify the Mac's APFS container to create the volume in."
        case .step(let label, let detail): "\(label) failed: \(detail)"
        }
    }
}

/// Secure Enclave identities via `sc_auth` + `ssh-keygen -K`. The private key is
/// generated inside the enclave and never leaves it; what lands in ~/.ssh is a
/// reference handle that is useless without the hardware and a touch.
struct EnclaveKeyService {
    let runner: any SystemCommandRunning
    init(runner: any SystemCommandRunning = ProcessRunner()) { self.runner = runner }

    func labels() async -> [String] {
        guard let r = try? await runner.run("/usr/sbin/sc_auth", ["list-ctk-identities"]) else { return [] }
        return r.stdout.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            // Key Type / Hash / Prot / Label ...
            return cols.count >= 4 ? String(cols[3]) : nil
        }
    }

    /// Biometry-gated P-256 in the enclave. Prompts Touch ID.
    func createIdentity(label: String) async throws {
        let r = try await runner.run("/usr/sbin/sc_auth",
                                     ["create-ctk-identity", "-l", label, "-k", "p-256-ne", "-t", "bio"])
        guard r.status == 0, await labels().contains(label) else {
            throw OrgCreationError.step("Creating the Secure Enclave key",
                                        firstNonEmpty(r.stderr, r.stdout, "sc_auth reported no new identity"))
        }
    }

    /// `ssh-keygen -K` dumps every resident key into the working directory, so
    /// export into a scratch dir and keep only the one we just made.
    func exportReferenceKey(label: String, to destination: String) async throws {
        let tmp = NSTemporaryDirectory() + "vaultkit-key-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let r = try await runner.run("/usr/bin/ssh-keygen",
                                     ["-w", "/usr/lib/ssh-keychain.dylib", "-K", "-N", ""],
                                     stdin: nil, cwd: tmp)
        let produced = (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []
        guard let priv = produced.first(where: { $0.hasSuffix(label) }) else {
            throw OrgCreationError.step("Exporting the reference key",
                                        firstNonEmpty(r.stderr, r.stdout, "no key file for \(label)"))
        }
        let fm = FileManager.default
        for (src, dst) in [(priv, destination), (priv + ".pub", destination + ".pub")] {
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            try fm.moveItem(atPath: "\(tmp)/\(src)", toPath: dst)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination + ".pub")
    }

    func publicKey(at path: String) -> String? {
        try? String(contentsOfFile: path + ".pub", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Surgical writes to the git configuration. Never rewrites what it did not
/// create: the per-org file is ours, and the root config is only appended to.
struct GitConfigService {
    let home: String
    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.home = home }

    func writeOrgConfig(_ org: Organization) throws {
        let body = """
        # Written by Vaultkit for the \(org.displayName) organization.
        [user]
        \tname = \(org.gitAuthorName)
        \temail = \(org.gitEmail)
        \tsigningkey = ~/.ssh/\(org.keyFileName)
        [core]
        \tsshCommand = ssh -i ~/.ssh/\(org.keyFileName) -o IdentitiesOnly=yes -o SecurityKeyProvider=/usr/lib/ssh-keychain.dylib
        [commit]
        \tgpgsign = true
        [tag]
        \tgpgSign = true

        """
        try body.write(toFile: "\(home)/.gitconfig-\(org.name)", atomically: true, encoding: .utf8)
    }

    func addInclude(_ org: Organization) throws {
        let path = "\(home)/.gitconfig"
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let rule = "[includeIf \"gitdir:~/work/\(org.name)/\"]\n\tpath = ~/.gitconfig-\(org.name)\n"
        guard !text.contains("gitdir:~/work/\(org.name)/") else { return }

        // Keep it with its siblings, above the /Volumes fallback block.
        if let marker = text.range(of: "# fallback:") {
            text.insert(contentsOf: rule, at: marker.lowerBound)
        } else {
            text += (text.hasSuffix("\n") ? "" : "\n") + rule
        }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// First non-blank of the candidates: pass the human fallback message last.
private func firstNonEmpty(_ values: String...) -> String {
    values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .first { !$0.isEmpty } ?? "unknown error"
}
