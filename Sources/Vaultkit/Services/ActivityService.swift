import Foundation

// MARK: - What is running, and what starts itself
//
// The Scanner reads files at rest. This is the other question a person asks
// after an incident: what is running right now, and what will start again
// after a reboot.
//
// Both matter for this family specifically. PolinRider's loader persists by
// spawning `node -e "<code>"` detached, with stdio ignored, so it survives the
// parent and keeps no terminal. The 2026 macOS campaigns add a LaunchAgent in
// ~/Library/LaunchAgents, which needs no administrator rights, survives
// reboots, and keeps working after the dropper itself is deleted.
//
// This reports and never kills anything. Terminating a process you have not
// identified is how people break their own machines, and the list gives you
// the pid to do it deliberately.

struct ActivityItem: Identifiable, Hashable {
    enum Kind: String {
        case process = "Running"
        case agent = "Login item"
        case daemon = "System item"
        case cron = "Scheduled"
    }

    var id: String
    var kind: Kind
    var title: String            // the command, or the agent's label
    var detail: String           // pid and elapsed time, or the plist path
    var path: String?            // revealable in Finder
    var reasons: [String]        // why it is flagged, empty when it is not
    var severity: DoctorFinding.Severity
}

struct ActivityService {
    private let runner: any SystemCommandRunning
    private let fm = FileManager.default

    init(runner: any SystemCommandRunning = ProcessRunner()) { self.runner = runner }

    // MARK: processes

    /// Interpreters told to run code given on the command line rather than
    /// from a file. Nothing legitimate needs to hide its source this way very
    /// often, and it is exactly how the loader persists.
    static let inlineCode: [(tool: String, flag: String)] = [
        ("node", " -e "), ("node", " --eval"), ("deno", " eval"), ("bun", " -e "),
        ("python", " -c "), ("python3", " -c "), ("ruby", " -e "), ("perl", " -e "),
        ("osascript", " -e "), ("php", " -r "),
    ]

    static let pipeToShell = ["| bash", "|bash", "| sh", "|sh", "| zsh", "curl -s", "wget -q"]
    static let scratchPaths = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
    static let scriptExtensions = ["sh", "bash", "zsh", "js", "mjs", "cjs", "py", "rb", "pl", "command"]

    /// What the command actually runs: the executable, plus any argument that
    /// names a script. Matching a path anywhere in the command line flags
    /// every tool that merely mentions one, which is how the first run of this
    /// rule flagged the test runner and a shell reading its own snapshot.
    static func executableTokens(_ cmd: String) -> [String] {
        let tokens = cmd.split(separator: " ").map(String.init)
        guard let executable = tokens.first else { return [] }
        var out = [executable]
        for t in tokens.dropFirst() where t.hasPrefix("/")
            && scriptExtensions.contains((t as NSString).pathExtension.lowercased()) {
            out.append(t)
        }
        return out
    }

    /// Flags for one command line. Empty means nothing stood out.
    static func reasons(forCommand cmd: String, vaultPaths: [String]) -> (reasons: [String], severity: DoctorFinding.Severity) {
        var reasons: [String] = []
        var severity = DoctorFinding.Severity.info
        let lower = cmd.lowercased()

        for (tool, flag) in inlineCode where lower.contains(tool) && lower.contains(flag) {
            reasons.append("runs code passed on the command line (\(tool)\(flag.trimmingCharacters(in: .whitespaces)))")
            severity = .critical
            break
        }
        if (lower.contains("curl") || lower.contains("wget")),
           pipeToShell.contains(where: { lower.contains($0) && $0.contains("sh") }) {
            reasons.append("downloads and pipes straight into a shell")
            severity = .critical
        }
        let runs = executableTokens(cmd)
        if let scratch = scratchPaths.first(where: { p in runs.contains { $0.lowercased().hasPrefix(p) } }) {
            reasons.append("runs from a temporary directory (\(scratch))")
            severity = max(severity, .warning)
        }
        if lower.contains("nc -l") || lower.contains("ncat -l") || lower.contains("netcat -l") {
            reasons.append("listens for inbound connections")
            severity = .critical
        }
        if let vault = vaultPaths.first(where: { v in runs.contains { $0.hasPrefix(v) } }) {
            reasons.append("running from inside the \((vault as NSString).lastPathComponent) vault")
            severity = max(severity, .warning)
        }
        return (reasons, severity)
    }

    /// Processes owned by this user. `etime` rather than `lstart` because it
    /// parses without ambiguity and "how long has this been up" is the more
    /// useful question anyway.
    func processes(vaultPaths: [String]) async -> [ActivityItem] {
        guard let r = try? await runner.run("/bin/ps", ["-xo", "pid=,ppid=,etime=,command="]),
              r.status == 0 else { return [] }
        var items: [ActivityItem] = []
        for line in r.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, let pid = Int(parts[0]) else { continue }
            let command = parts.dropFirst(3).joined(separator: " ")
            guard !command.isEmpty else { continue }
            let (reasons, severity) = Self.reasons(forCommand: command, vaultPaths: vaultPaths)
            guard !reasons.isEmpty else { continue }   // the flagged ones only
            items.append(ActivityItem(
                id: "pid-\(pid)", kind: .process,
                title: String(command.prefix(400)),
                detail: "pid \(pid), parent \(parts[1]), up \(parts[2])",
                path: nil, reasons: reasons, severity: severity))
        }
        return items
    }

    // MARK: persistence

    static let agentDirectories = [
        ("\(NSHomeDirectory())/Library/LaunchAgents", ActivityItem.Kind.agent),
        ("/Library/LaunchAgents", ActivityItem.Kind.agent),
        ("/Library/LaunchDaemons", ActivityItem.Kind.daemon),
    ]

    /// Everything that starts on its own, Apple's own excluded: those live in
    /// /System/Library, which is signed and read-only. Third-party items are
    /// all listed, because "what starts itself" is a question worth answering
    /// in full, and the suspicious ones are flagged on top.
    func persistence() -> [ActivityItem] {
        var items: [ActivityItem] = []
        for (dir, kind) in Self.agentDirectories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".plist") {
                let path = "\(dir)/\(name)"
                guard let data = fm.contents(atPath: path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                        as? [String: Any] else { continue }

                let label = (plist["Label"] as? String) ?? (name as NSString).deletingPathExtension
                var argv = (plist["ProgramArguments"] as? [String]) ?? []
                if let program = plist["Program"] as? String, argv.isEmpty { argv = [program] }
                let command = argv.joined(separator: " ")

                var (reasons, severity) = Self.reasons(forCommand: command, vaultPaths: [])
                if plist["RunAtLoad"] as? Bool == true, !reasons.isEmpty {
                    reasons.append("starts at login")
                }
                if let interval = plist["StartInterval"] as? Int, !reasons.isEmpty {
                    reasons.append("re-runs every \(interval)s")
                }
                if plist["ProgramArguments"] == nil, plist["Program"] == nil {
                    reasons.append("declares no program, which is unusual")
                    severity = max(severity, .warning)
                }
                items.append(ActivityItem(
                    id: path, kind: kind, title: label,
                    detail: command.isEmpty ? path : String(command.prefix(400)),
                    path: path, reasons: reasons, severity: severity))
            }
        }
        return items
    }

    /// The user's crontab, which survives reboots and nothing in the UI shows.
    func cron() async -> [ActivityItem] {
        guard let r = try? await runner.run("/usr/bin/crontab", ["-l"]), r.status == 0 else { return [] }
        return r.stdout.split(separator: "\n").enumerated().compactMap { i, raw in
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty, !entry.hasPrefix("#") else { return nil }
            let (reasons, severity) = Self.reasons(forCommand: entry, vaultPaths: [])
            return ActivityItem(id: "cron-\(i)", kind: .cron, title: entry,
                                detail: "user crontab", path: nil,
                                reasons: reasons, severity: severity)
        }
    }

    /// Everything, worst first, with flagged items above quiet ones.
    func snapshot(vaultPaths: [String]) async -> [ActivityItem] {
        var all = await processes(vaultPaths: vaultPaths)
        all += persistence()
        all += await cron()
        return all.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.reasons.isEmpty != $1.reasons.isEmpty { return !$0.reasons.isEmpty }
            return $0.title < $1.title
        }
    }
}
