import Foundation

// MARK: - Indicators
//
// The PolinRider campaign (DPRK, 2026) appends an obfuscated loader to build
// config files, leaves a propagation script behind, ships malicious Tailwind
// look-alike npm packages, and abuses VS Code's runOn:folderOpen tasks. These
// indicators are transcribed from OpenSourceMalware's write-up and scanner and
// carry that set's date, so a user can tell at a glance how current they are.
//
// This is targeted indicator matching, not an antivirus: it finds what it has
// indicators for and nothing else.

enum PolinRiderIndicators {
    static let version = "2026-04-11"
    static let source = "https://github.com/OpenSourceMalware/PolinRider"

    struct Marker: Hashable {
        let text: String
        let name: String
    }

    /// Each of these is definitive on its own (0 false positives in OSM's sampling).
    static let payloadMarkers: [Marker] = [
        Marker(text: "rmcej%otb%", name: "PolinRider loader — original variant (rmcej%otb%)"),
        Marker(text: "Cot%3t=shtP", name: "PolinRider loader — rotated variant (Cot%3t=shtP)"),
        Marker(text: "_$_1e42", name: "PolinRider decoder function (_$_1e42)"),
    ]

    // Conjunctions from the published multi-variant YARA rule.
    static let v1Global = "global['!']"
    static let v1Seeds = ["2857687", "2667686"]
    static let v2Global = "global['_V']"
    static let v2Seeds = ["1111436", "3896884"]
    static let v2Decoder = "function MDy("
    static let globalRequire = "global['r'] = require"
    static let globalModule = "global['m'] = module"

    /// Second-stage dead-drop and bootstrap infrastructure. Specific enough
    /// that a match in any file is a finding.
    static let c2Markers: [Marker] = [
        Marker(text: "TMfKQEd7TJJa5xNZJZ2Lep838vrzrs7mAP", name: "PolinRider C2 — TRON dead-drop (primary)"),
        Marker(text: "TXfxHUet9pJVU1BgVkBAbrES4YUc1nGzcG", name: "PolinRider C2 — TRON dead-drop (secondary)"),
        Marker(text: "0xbe037400670fbf1c32364f762975908dc43eeb38759263e7dfcdabc76380811e", name: "PolinRider C2 — Aptos dead-drop (primary)"),
        Marker(text: "0x3f0e5781d0855fb460661ac63257376db1941b2bb522499e4757ecb3ebd5dce3", name: "PolinRider C2 — Aptos dead-drop (secondary)"),
        Marker(text: "2[gWfGj;<:-93Z^C", name: "PolinRider XOR key (primary)"),
        Marker(text: "m6:tTh^D)cBz?NM]", name: "PolinRider XOR key (secondary)"),
        Marker(text: "260120.vercel.app", name: "PolinRider bootstrap host (260120.vercel.app)"),
        Marker(text: "default-configuration.vercel.app", name: "PolinRider bootstrap host (default-configuration.vercel.app)"),
        Marker(text: "vscode-settings-bootstrap.vercel.app", name: "PolinRider bootstrap host (vscode-settings-bootstrap.vercel.app)"),
        Marker(text: "vscode-settings-config.vercel.app", name: "PolinRider bootstrap host (vscode-settings-config.vercel.app)"),
        Marker(text: "vscode-bootstrapper.vercel.app", name: "PolinRider bootstrap host (vscode-bootstrapper.vercel.app)"),
        Marker(text: "vscode-load-config.vercel.app", name: "PolinRider bootstrap host (vscode-load-config.vercel.app)"),
    ]

    /// The StakingGame take-home template's constant projectInfo.uuid.
    static let stakingGameUUID = "e9b53a7c-2342-4b15-b02d-bd8b8f6a03f9"

    /// npm packages published by the actor, impersonating Tailwind utilities.
    static let maliciousPackages: [String] = [
        "tailwindcss-style-animate", "tailwind-mainanimation", "tailwind-autoanimation",
        "tailwind-animationbased", "tailwindcss-typography-style", "tailwindcss-style-modify",
        "tailwindcss-animate-style",
    ]

    /// Files the loader is appended to. Checked wherever they occur, not only
    /// at the repo root — many victims are infected only in nested paths.
    static func isTargetConfig(_ name: String) -> Bool {
        let stems = ["postcss.config", "tailwind.config", "eslint.config", "next.config",
                     "babel.config", "jest.config", "vite.config", "vitest.config",
                     "webpack.config", "astro.config", "gridsome.config", "vue.config",
                     "nuxt.config", "svelte.config", "rollup.config"]
        if stems.contains(where: { name.hasPrefix($0 + ".") }) { return true }
        return ["truffle.js", "truffle-config.js", "App.js", "app.js",
                "index.js", "index.mjs", "index.cjs"].contains(name)
    }

    /// A deep scan widens to every JS-family source file.
    static func isDeepTarget(_ name: String) -> Bool {
        ["js", "mjs", "cjs", "ts", "tsx", "jsx", "html"]
            .contains((name as NSString).pathExtension.lowercased())
    }
}

// MARK: - Scanner

/// Watches every mounted vault for the campaign's indicators (UC12).
///
/// Read-only by construction: it opens files and matches bytes, never edits a
/// repository. Incremental between ticks — a file is re-read only if its
/// content *or inode* changed since the vault's last pass. Change detection is
/// on ctime as well as mtime because the campaign's own propagation script
/// rewinds the clock to forge timestamps: mtime can be set from user space,
/// ctime cannot.
actor ScannerService {

    struct Report: Sendable {
        var startedAt: Date
        var finishedAt: Date
        var filesScanned: Int
        var reposSeen: Int
        var orgsScanned: [String]
        var full: Bool                    // at least one org got a first/full pass
        var deep: Bool
        var indicatorVersion: String { PolinRiderIndicators.version }
    }

    /// Directories never descended into. node_modules is checked for the
    /// known-malicious package names at its top level, then skipped.
    static let pruned: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "out", ".next", ".nuxt",
        ".svelte-kit", ".cache", ".turbo", ".parcel-cache", "coverage", ".pnpm-store",
        "Pods", "DerivedData", ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
    ]

    /// Largest file the byte matcher will read. Config files are kilobytes;
    /// anything bigger is not one of them.
    static let maxBytes = 4 * 1024 * 1024

    private var baseline: [String: Date] = [:]          // org name → last pass start
    private var findings: [String: [ScanFinding]] = [:] // org name → current findings

    private let fm = FileManager.default

    func currentFindings() -> [ScanFinding] {
        findings.values.flatMap { $0 }.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.path < $1.path
        }
    }

    /// Scan every mounted org. Orgs that are not mounted drop their findings
    /// and baseline: their content is at rest, and the next mount deserves a
    /// full pass rather than a diff against a stale one.
    func scan(orgs: [Organization], deep: Bool = false) -> (Report, [ScanFinding]) {
        let start = Date()
        var files = 0, repos = 0, scanned: [String] = [], full = false

        let mounted = Set(orgs.filter { $0.vault == .mounted }.map(\.name))
        for name in Array(findings.keys) where !mounted.contains(name) {
            findings[name] = nil
            baseline[name] = nil
        }

        for org in orgs where org.vault == .mounted {
            // A deep scan always re-reads everything it widens to.
            let since = deep ? nil : baseline[org.name]
            if since == nil { full = true }
            let result = scanOrg(org, since: since, deep: deep)
            files += result.files
            repos += result.repos
            scanned.append(org.name)

            var kept = since == nil ? [] : (findings[org.name] ?? [])
            // Drop findings for files this pass re-evaluated or that vanished.
            kept.removeAll { result.touched.contains($0.path) || !fm.fileExists(atPath: $0.absolutePath) }
            findings[org.name] = kept + result.findings
            baseline[org.name] = start
        }

        let report = Report(startedAt: start, finishedAt: Date(), filesScanned: files,
                            reposSeen: repos, orgsScanned: scanned, full: full, deep: deep)
        return (report, currentFindings())
    }

    // MARK: one org

    private struct OrgResult {
        var findings: [ScanFinding] = []
        var touched: Set<String> = []      // relative paths re-evaluated this pass
        var files = 0
        var repos = 0
    }

    private func scanOrg(_ org: Organization, since: Date?, deep: Bool) -> OrgResult {
        // The enumerator yields canonical paths (/private/var/…) whatever it was
        // handed, so canonicalize the root the same way or relative paths are
        // cut at the wrong offset. realpath(3), not resolvingSymlinksInPath —
        // Foundation's strips /private and lands on the other side of the gap.
        let root = URL(fileURLWithPath: Self.canonical((org.folderPath as NSString).expandingTildeInPath))
        var result = OrgResult()
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey, .fileSizeKey,
                                      .contentModificationDateKey, .attributeModificationDateKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [], errorHandler: { _, _ in true }) else { return result }

        let rootPath = root.path
        var repoRoots = RepoRoots(top: rootPath)

        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let name = values.name else { continue }
            let path = url.path

            if values.isDirectory == true {
                if name == ".git" {
                    result.repos += 1
                    walker.skipDescendants()
                } else if name == "node_modules" {
                    result.findings += maliciousInstalledPackages(
                        at: url, org: org, root: rootPath,
                        repo: repoRoots.name(for: path, fallback: org.name))
                    walker.skipDescendants()
                } else if Self.pruned.contains(name) {
                    walker.skipDescendants()
                }
                continue
            }

            guard let kind = Self.classify(name: name, path: path, deep: deep) else { continue }

            // Incremental: skip files untouched since the last pass.
            if let since {
                let m = values.contentModificationDate ?? .distantPast
                let c = values.attributeModificationDate ?? .distantPast
                if max(m, c) <= since { continue }
            }

            let rel = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : name
            result.touched.insert(rel)
            result.files += 1
            let repo = repoRoots.name(for: path, fallback: org.name)
            result.findings += check(url, kind: kind, size: values.fileSize ?? 0,
                                     org: org, repo: repo, rel: rel)
        }
        return result
    }

    private enum FileKind { case config, source, packageJSON, tasksJSON, gitignore, batch, font }

    private static func classify(name: String, path: String, deep: Bool) -> FileKind? {
        let lower = name.lowercased()
        if name == "package.json" { return .packageJSON }
        if name == ".gitignore" { return .gitignore }
        if lower == "tasks.json", path.hasSuffix("/.vscode/tasks.json") { return .tasksJSON }
        if lower.hasSuffix(".bat") { return .batch }
        if lower.hasSuffix(".woff") || lower.hasSuffix(".woff2") { return .font }
        if PolinRiderIndicators.isTargetConfig(name) { return .config }
        if deep, PolinRiderIndicators.isDeepTarget(name) { return .source }
        return nil
    }

    /// Nearest enclosing git repository, found by walking up from the file
    /// rather than from enumeration order — a directory's `.git` is not
    /// guaranteed to be visited before its siblings. Memoized per directory.
    private struct RepoRoots {
        let top: String
        private var memo: [String: String?] = [:]

        init(top: String) { self.top = top }

        mutating func name(for path: String, fallback: String) -> String {
            root(of: (path as NSString).deletingLastPathComponent)
                .map { ($0 as NSString).lastPathComponent } ?? fallback
        }

        private mutating func root(of dir: String) -> String? {
            if let cached = memo[dir] { return cached }
            let found: String?
            if FileManager.default.fileExists(atPath: dir + "/.git") {
                found = dir
            } else if dir == top || dir == "/" || !dir.hasPrefix(top) {
                found = nil
            } else {
                found = root(of: (dir as NSString).deletingLastPathComponent)
            }
            memo[dir] = found
            return found
        }
    }

    // MARK: per-file checks

    private func check(_ url: URL, kind: FileKind, size: Int, org: Organization,
                       repo: String, rel: String) -> [ScanFinding] {
        func finding(_ indicator: String, _ severity: DoctorFinding.Severity,
                     _ evidence: String, _ remediation: String) -> ScanFinding {
            ScanFinding(orgName: org.name, repo: repo, path: rel, absolutePath: url.path,
                        indicator: indicator, severity: severity, evidence: evidence,
                        remediation: remediation)
        }

        switch kind {
        case .batch:
            let name = url.lastPathComponent
            if name == "temp_auto_push.bat" {
                return [finding("PolinRider propagation script", .critical, name, Remedy.propagation)]
            }
            if name == "config.bat" {
                return [finding("PolinRider orchestrator script", .critical, name, Remedy.propagation)]
            }
            guard let data = read(url, size: size) else { return [] }
            if data.contains("LAST_COMMIT_DATE"), data.contains("--amend") {
                return [finding("Commit-amending batch script (PolinRider pattern)", .critical,
                                "LAST_COMMIT_DATE + --amend", Remedy.propagation)]
            }
            return []

        case .gitignore:
            guard let data = read(url, size: size), let text = String(data: data, encoding: .utf8) else { return [] }
            let injected = text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "config.bat" }
            return injected ? [finding("Injected .gitignore entry", .warning, "config.bat", Remedy.gitignore)] : []

        case .packageJSON:
            guard let data = read(url, size: size) else { return [] }
            return maliciousDependencies(in: data).map {
                finding("Malicious npm dependency", .critical, $0, Remedy.dependency)
            }

        case .tasksJSON:
            guard let data = read(url, size: size) else { return [] }
            var out: [ScanFinding] = []
            if data.contains(PolinRiderIndicators.stakingGameUUID) {
                out.append(finding("StakingGame take-home template", .critical,
                                   "projectInfo.uuid \(PolinRiderIndicators.stakingGameUUID)", Remedy.tasks))
            }
            out += c2Hits(in: data).map { finding($0.name, .critical, $0.text, Remedy.tasks) }
            if out.isEmpty, data.contains("folderOpen"),
               ["curl ", "wget ", "| bash", "| sh", "Invoke-WebRequest", "powershell"].contains(where: data.contains) {
                out.append(finding("VS Code task fetches and runs code on folder open", .warning,
                                   "runOn: folderOpen + shell download", Remedy.tasks))
            }
            return out

        case .font:
            // A real WOFF/WOFF2 starts with its magic; the campaign hides JS
            // payloads in files named like fonts. Only the head is read.
            guard let head = readHead(url, bytes: 4096) else { return [] }
            let magic = head.prefix(4)
            let isFont = magic == Data("wOFF".utf8) || magic == Data("wOF2".utf8)
            if isFont { return [] }
            let looksLikeJS = ["global[", "require(", "function", "eval("].contains { head.contains($0) }
            return looksLikeJS
                ? [finding("JavaScript hidden in a font file", .critical, "no WOFF magic; script text", Remedy.font)]
                : [finding("Font file that is not a font", .warning, "no WOFF magic", Remedy.font)]

        case .config, .source:
            guard let data = read(url, size: size) else { return [] }
            var out: [ScanFinding] = []
            out += payloadHits(in: data).map { finding($0.name, .critical, $0.text, Remedy.payload) }
            out += c2Hits(in: data).map { finding($0.name, .critical, $0.text, Remedy.payload) }
            return out
        }
    }

    // MARK: matchers

    private func payloadHits(in data: Data) -> [PolinRiderIndicators.Marker] {
        var hits = PolinRiderIndicators.payloadMarkers.filter { data.contains($0.text) }
        let I = PolinRiderIndicators.self
        if data.contains(I.v1Global), I.v1Seeds.contains(where: data.contains) {
            hits.append(.init(text: "global['!'] + seed", name: "PolinRider loader — original variant (structure)"))
        }
        if data.contains(I.v2Global),
           I.v2Seeds.contains(where: data.contains) || data.contains(I.v2Decoder) {
            hits.append(.init(text: "global['_V'] + seed/decoder", name: "PolinRider loader — rotated variant (structure)"))
        }
        if data.contains(I.globalRequire), data.contains(I.globalModule),
           (I.v1Seeds + I.v2Seeds).contains(where: data.contains) {
            hits.append(.init(text: "global['r']/global['m'] + seed", name: "PolinRider loader (shared structure)"))
        }
        return hits
    }

    private func c2Hits(in data: Data) -> [PolinRiderIndicators.Marker] {
        PolinRiderIndicators.c2Markers.filter { data.contains($0.text) }
    }

    private func maliciousDependencies(in data: Data) -> [String] {
        // Parse when possible so a package merely *mentioned* in a description
        // does not count; fall back to a byte match on malformed JSON.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var names: Set<String> = []
            for section in ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"] {
                for key in (json[section] as? [String: Any])?.keys ?? [:].keys {
                    if PolinRiderIndicators.maliciousPackages.contains(key) { names.insert(key) }
                }
            }
            return names.sorted()
        }
        return PolinRiderIndicators.maliciousPackages.filter { data.contains("\"\($0)\"") }
    }

    private func maliciousInstalledPackages(at nodeModules: URL, org: Organization,
                                            root: String, repo: String) -> [ScanFinding] {
        guard let entries = try? fm.contentsOfDirectory(atPath: nodeModules.path) else { return [] }
        return entries.filter(PolinRiderIndicators.maliciousPackages.contains).map { pkg in
            ScanFinding(orgName: org.name, repo: repo,
                        path: String(nodeModules.path.dropFirst(root.count + 1)) + "/" + pkg,
                        absolutePath: nodeModules.path + "/" + pkg,
                        indicator: "Malicious npm package installed", severity: .critical,
                        evidence: pkg, remediation: Remedy.dependency)
        }
    }

    // MARK: IO

    private static func canonical(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    private func read(_ url: URL, size: Int) -> Data? {
        guard size <= Self.maxBytes else { return nil }
        return try? Data(contentsOf: url, options: [.uncached])
    }

    private func readHead(_ url: URL, bytes: Int) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        return try? h.read(upToCount: bytes)
    }
}

/// What to do about each class of hit — OSM's remediation, in the order that
/// matters. Vaultkit never edits repository files itself.
enum Remedy {
    static let payload = "Delete everything appended after the legitimate config (from the injected global[…] line to the end of the file). Check the last commits for an amend that carried it, and rotate every secret that was in the environment during a build."
    static let propagation = "Direct evidence of compromise even if the payload was cleaned. Delete it, rotate credentials, inspect the reflog for amended commits, and check global npm packages and editor extensions for the dropper."
    static let gitignore = "Remove the config.bat line — the malware adds it to keep its orchestrator out of diffs."
    static let dependency = "Remove the package, delete node_modules and the lockfile entry, and treat any machine that ever installed it as compromised."
    static let tasks = "Delete the task. With runOn: folderOpen it runs the moment an editor opens this folder — do not open it in VS Code until it is gone."
    static let font = "A file named like a font that is not one. The campaign hides loaders in .woff2 files; remove it and find what imports it."
}

extension Data {
    /// Byte-level substring test — files are matched raw, so binary content
    /// and invalid UTF-8 never derail a scan.
    func contains(_ needle: String) -> Bool {
        range(of: Data(needle.utf8)) != nil
    }
}
