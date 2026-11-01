import Foundation

/// One refused rewrite, as the hook journalled it before turning it down.
struct RewriteAttempt: Identifiable, Equatable {
    let at: Date
    let repoPath: String
    let ref: String
    let oldOID: String
    let newOID: String

    var id: String { "\(at.timeIntervalSince1970)-\(ref)-\(newOID)" }
    var repo: String { (repoPath as NSString).lastPathComponent }
    var branch: String { ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref }
}

/// Refuses history rewriting inside the vaults, and records every attempt.
///
/// Rewriting is how a tampered commit is made to look ordinary: PolinRider
/// amended its loader into commits that already had an author and a date, which
/// is why the Scanner treats `LAST_COMMIT_DATE` next to `--amend` as a
/// compromise indicator. It is also what erases a signature mismatch, the one
/// signal the Doctor has that a commit changed after it was signed.
///
/// A `reference-transaction` hook rather than `pre-commit`: it fires on the ref
/// update itself, so it covers amend, rebase and reset alike, and `--no-verify`
/// does not skip it (verified against git 2.x, both paths). What it cannot do
/// is stop something that can write to `.git`, repoint `core.hooksPath`, or
/// call plumbing directly. This is a guard rail with an alarm on it, not
/// containment, and the alarm is the part that matters: an attempt is
/// journalled before it is refused, so a rewrite that goes around the hook is
/// still visible as the Doctor's signature findings.
struct RewriteGuard {
    static let defaultsKey = "vk.blockHistoryRewrites"
    /// Organizations the guard leaves alone, by `org.name`. Rebasing your own
    /// side projects is ordinary work; rewriting a client's signed history is
    /// the thing worth refusing, and the two can live on one Mac.
    static let exemptKey = "vk.blockHistoryRewrites.exempt"
    /// The hook is recognised by this line, so Vaultkit only ever replaces or
    /// removes a file it wrote. Another tool's hook is reported, never touched.
    static let marker = "# vaultkit-rewrite-guard"

    private let fm = FileManager.default
    let journal: URL

    init(journal: URL? = nil) {
        self.journal = journal ?? fm
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vaultkit/rewrite-attempts.log")
    }

    /// What one pass over the vaults could and could not protect.
    struct Report: Equatable {
        var protected: [String] = []    // repo names now carrying the hook
        var conflicted: [String] = []   // repo names where another tool owns it
    }

    static func exempt(in d: UserDefaults = .standard) -> Set<String> {
        Set(d.object(forKey: exemptKey) as? [String] ?? [])
    }

    static func setExempt(_ names: Set<String>, in d: UserDefaults = .standard) {
        d.set(Array(names).sorted(), forKey: exemptKey)
    }

    // MARK: the hook

    static func script(journal: String) -> String {
        """
        #!/bin/sh
        \(marker)
        #
        # Refuses any update to a local branch that is not a fast-forward, which
        # is what amend, rebase, reset backwards and force updates all look like
        # at the ref. Written and overwritten by Vaultkit: turn it off under
        # Settings rather than editing it, or it will come back.
        [ "$1" = "prepared" ] || exit 0

        journal='\(journal.replacingOccurrences(of: "'", with: "'\\''"))'
        blocked=0

        while read -r old new ref; do
            case "$ref" in
                refs/heads/*) ;;
                *) continue ;;
            esac
            # An all-zero side means the branch is being created or deleted.
            # Neither replaces an existing commit.
            case "$old" in *[!0]*) ;; *) continue ;; esac
            case "$new" in *[!0]*) ;; *) continue ;; esac
            # A fast-forward leaves every commit that was reachable still
            # reachable. Anything else drops or replaces one.
            if git merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
                continue
            fi
            mkdir -p "${journal%/*}"
            printf '%s\\t%s\\t%s\\t%s\\t%s\\n' \\
                "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(pwd)" "$ref" "$old" "$new" >> "$journal"
            blocked=1
            echo "Vaultkit: refused to rewrite ${ref#refs/heads/} in $(basename "$(pwd)")." >&2
        done

        [ "$blocked" = 0 ] || {
            echo "  Replacing a signed commit is how an altered one is made to look" >&2
            echo "  ordinary, and how a signature mismatch is erased. The attempt has" >&2
            echo "  been recorded. To allow it, turn off \\"Block history rewriting\\"" >&2
            echo "  in Vaultkit under Settings." >&2
            exit 1
        }
        exit 0
        """
    }

    // MARK: installing

    /// Idempotent: safe to call on every Doctor run, which is how repositories
    /// cloned since the last pass pick the hook up.
    func install(in orgs: [Organization]) -> Report {
        var report = Report()
        for repo in repositories(in: orgs) {
            let hook = "\(repo)/.git/hooks/reference-transaction"
            let name = (repo as NSString).lastPathComponent
            if let existing = try? String(contentsOfFile: hook, encoding: .utf8),
               !existing.contains(Self.marker) {
                report.conflicted.append(name)
                continue
            }
            let text = Self.script(journal: journal.path)
            guard (try? fm.createDirectory(atPath: "\(repo)/.git/hooks",
                                           withIntermediateDirectories: true)) != nil,
                  (try? text.write(toFile: hook, atomically: true, encoding: .utf8)) != nil,
                  (try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)) != nil
            else { continue }
            report.protected.append(name)
        }
        return report
    }

    /// Removes only hooks Vaultkit wrote. Someone else's file of the same name
    /// is left exactly where it is.
    func uninstall(from orgs: [Organization]) {
        for repo in repositories(in: orgs) {
            let hook = "\(repo)/.git/hooks/reference-transaction"
            guard let existing = try? String(contentsOfFile: hook, encoding: .utf8),
                  existing.contains(Self.marker) else { continue }
            try? fm.removeItem(atPath: hook)
        }
    }

    /// Repositories directly inside a mounted vault. A `.git` file rather than
    /// a directory means a worktree or submodule, whose hooks live elsewhere.
    private func repositories(in orgs: [Organization]) -> [String] {
        var found: [String] = []
        for org in orgs where org.vault == .mounted {
            let root = (org.folderPath as NSString).expandingTildeInPath
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names.sorted() {
                var isDirectory: ObjCBool = false
                let git = "\(root)/\(name)/.git"
                guard fm.fileExists(atPath: git, isDirectory: &isDirectory), isDirectory.boolValue
                else { continue }
                found.append("\(root)/\(name)")
            }
        }
        return found
    }

    // MARK: the journal

    /// Newest first. A line the hook wrote while the app was closed is read the
    /// next time it opens, so nothing is lost by not watching the file.
    func attempts(limit: Int = 100) -> [RewriteAttempt] {
        guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return [] }
        let formatter = ISO8601DateFormatter()
        return text.split(separator: "\n").reversed().prefix(limit).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 5, let at = formatter.date(from: String(f[0])) else { return nil }
            return RewriteAttempt(at: at, repoPath: String(f[1]), ref: String(f[2]),
                                  oldOID: String(f[3]), newOID: String(f[4]))
        }
    }

    func forgetAttempts() {
        try? fm.removeItem(at: journal)
    }
}
