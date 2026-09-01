import Foundation

enum GitError: LocalizedError {
    case invalidURL(String)
    case hostNotPinned(String)
    case vaultNotMounted(String)
    case cloneFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            "\"\(url)\" doesn't look like an SSH clone URL (git@host:path or ssh://…)."
        case .hostNotPinned(let host):
            "\(host) is not in your verified known_hosts. Verify its host-key fingerprints out-of-band and pin them before cloning — never on first use after an incident."
        case .vaultNotMounted(let org):
            "Mount the \(org) vault first — clones must land inside it, not on the bare disk."
        case .cloneFailed(let detail):
            detail
        }
    }
}

/// Clones repositories INTO an org's mounted vault with that org's enclave key.
/// The URL, key, and destination are bound together by construction — the
/// cross-org misrouting this app exists to prevent can't happen through here.
final class GitService: @unchecked Sendable {
    private let runner: any SystemCommandRunning

    init(runner: any SystemCommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    /// "git@host:path" or "ssh://git@host[:port]/path" → host
    static func host(of url: String) -> String? {
        if url.hasPrefix("ssh://"), let u = URL(string: url) { return u.host }
        guard let at = url.firstIndex(of: "@"),
              let colon = url[at...].firstIndex(of: ":") else { return nil }
        let host = String(url[url.index(after: at)..<colon])
        return host.isEmpty ? nil : host
    }

    /// True when the host appears in ~/.ssh/known_hosts (plain or [host]:port).
    static func isPinned(host: String) -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.ssh/known_hosts"
        guard let known = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return known.split(separator: "\n").contains { line in
            let first = line.split(separator: " ").first.map(String.init) ?? ""
            return first.split(separator: ",").contains { entry in
                entry == host[...] || entry.hasPrefix("[\(host)]:")
            }
        }
    }

    /// Returns the cloned repository's folder name.
    func clone(url: String, into org: Organization) async throws -> String {
        guard org.vault == .mounted else { throw GitError.vaultNotMounted(org.displayName) }
        guard let host = Self.host(of: url) else { throw GitError.invalidURL(url) }
        guard Self.isPinned(host: host) else { throw GitError.hostNotPinned(host) }

        let folder = (org.folderPath as NSString).expandingTildeInPath
        // includeIf gitdir config isn't reliably applied DURING clone, so pass
        // the org's sshCommand explicitly; -c also persists it in the new repo
        // harmlessly (the includeIf takes over afterwards).
        var args = ["clone"]
        if let ssh = org.sshCommand {
            args += ["-c", "core.sshCommand=\(ssh)"]
        }
        args.append(url)

        let r = try await runner.run("/usr/bin/git", args, stdin: nil, cwd: folder)
        guard r.status == 0 else {
            let detail = [r.stderr, r.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "git clone failed"
            throw GitError.cloneFailed(detail)
        }
        let name = url.split(separator: "/").last.map(String.init)?
            .replacingOccurrences(of: ".git", with: "") ?? "repository"
        return name
    }
}
