import Foundation

// MARK: - Behavioural detection
//
// PolinRider is matched by fixed strings. This is the other half: code that
// announces itself by what it does rather than by what it is called.
//
// The 2026 npm campaigns made single-string matching useless on its own. The
// compromised axios releases split their atob() calls across two halves purely
// to defeat grep, and the node-gyp worm moved its trigger into binding.gyp so
// there was no postinstall line to find. What none of them can hide is the
// shape: decode something, fetch something, run it. So this looks for signals
// co-occurring inside a window rather than for any one literal.
//
// Everything here is a heuristic, which is why no behavioural finding is ever
// auto-actioned. They carry `.manual`, so the Scanner reports and the human
// decides. A false positive must never cost somebody a source file.

enum Behaviour {

    enum Signal: String, CaseIterable {
        case decode      = "decodes data"
        case network     = "fetches over the network"
        case execute     = "executes code at runtime"
        case envSource   = "reads an environment variable"
        case detach      = "detaches the child process"
        case obfuscation = "hides an identifier from search"
        case encodedBlob = "carries a long encoded blob"
    }

    struct Hit {
        let indicator: String
        let severity: DoctorFinding.Severity
        let evidence: String
        let remediation: String
    }

    /// Substring triggers per signal. Lower-cased comparison, so a rename to
    /// `Eval` or `ATOB` still lands.
    static let triggers: [Signal: [String]] = [
        .decode: ["atob(", "from(atob", "'base64'", "\"base64\"", "fromcharcode(", "unescape("],
        .network: ["node-fetch", "axios", "https.get", "https.request", "http.get",
                   "fetch(", "xmlhttprequest", "undici", "got(", "request(", "curl "],
        .execute: ["eval(", "new function(", "runinthiscontext", "runinnewcontext",
                   "child_process", "execsync(", "spawnsync(", "\"exec\"", "'exec'"],
        .envSource: ["process.env."],
        .detach: ["detached: true", "detached:true", "stdio: 'ignore'", "stdio:'ignore'",
                  "windowshide"],
    ]

    /// A line long enough that the file is a build artefact rather than
    /// something a person edits. Bundles legitimately contain eval and fetch,
    /// so signals there are reported, but never as critical.
    static let minifiedLineLength = 1000
    /// Signals count as related only if they sit this close together.
    static let window = 20

    /// Identifier assembled from fragments, which only an obfuscator writes:
    /// `'ev' + 'al'`, or hex escapes spelling a name.
    static func looksObfuscated(_ line: String) -> Bool {
        if line.range(of: #"['"][A-Za-z]{1,4}['"]\s*\+\s*['"][A-Za-z]{1,4}['"]"#,
                      options: .regularExpression) != nil { return true }
        if line.range(of: #"(\\x[0-9a-fA-F]{2}){4,}"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// A long base64 run. Deliberately NOT treated as obfuscation on its own:
    /// embedded assets are everywhere, and the first thing this rule found in
    /// the wild was a 22KB PNG noise texture inlined as a data URI. It only
    /// means something next to code that decodes or runs it, and a self
    /// describing `data:` URI is excluded outright.
    static func hasEncodedBlob(_ line: String) -> Bool {
        guard !line.contains("data:") else { return false }
        return line.range(of: #"[A-Za-z0-9+/]{220,}={0,2}"#, options: .regularExpression) != nil
    }

    /// Signals present in a file, with the line each was seen on.
    static func signals(in text: String) -> (found: [Signal: [Int]], minified: Bool) {
        var found: [Signal: [Int]] = [:]
        var minified = false
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if raw.count > minifiedLineLength { minified = true }
            let line = raw.lowercased()
            for (signal, needles) in triggers where needles.contains(where: line.contains) {
                found[signal, default: []].append(i)
            }
            if looksObfuscated(String(raw)) {
                found[.obfuscation, default: []].append(i)
            }
            if hasEncodedBlob(String(raw)) {
                found[.encodedBlob, default: []].append(i)
            }
        }
        return (found, minified)
    }

    /// Closest pair of lines carrying two signals, when they are near enough
    /// to be part of one gesture.
    private static func near(_ a: [Int]?, _ b: [Int]?) -> (Int, Int)? {
        guard let a, let b else { return nil }
        var best: (Int, Int)?
        for x in a {
            for y in b where abs(x - y) <= window {
                if best == nil || abs(x - y) < abs(best!.0 - best!.1) { best = (x, y) }
            }
        }
        return best
    }

    private static func line(_ n: Int) -> String { "line \(n + 1)" }

    /// The rules. Order matters: the first match wins, strongest first.
    static func analyse(text: String) -> Hit? {
        let (found, minified) = signals(in: text)
        guard !found.isEmpty else { return nil }

        // Minification erases the structure this whole file depends on. Every
        // rule below asks whether two signals sit within `window` lines of each
        // other, and jQuery 3.7.1 is a single line of 87KB: every signal lands
        // on line 1, every distance is zero, and the proximity test degenerates
        // into "does this file contain a fetch and an eval anywhere", which is
        // true of every substantial JavaScript library ever shipped. Reporting
        // it as a downgraded warning was papering over a rule that cannot run
        // on this input. Signature matching is byte exact and unaffected, so a
        // known-malicious bundle is still caught; it is only the behavioural
        // guess that has nothing to work with.
        guard !minified else { return nil }

        func hit(_ indicator: String, _ severity: DoctorFinding.Severity,
                 _ evidence: String, _ remediation: String) -> Hit {
            Hit(indicator: indicator, severity: severity,
                evidence: evidence, remediation: remediation)
        }

        if let (e, n) = near(found[.execute], found[.network]) {
            return hit("Fetches and runs remote code", .critical,
                       "\(Signal.network.rawValue) at \(line(n)), \(Signal.execute.rawValue) at \(line(e))",
                       Remedy.remoteExec)
        }
        if let (e, d) = near(found[.execute], found[.decode]) {
            return hit("Runs decoded code", .critical,
                       "\(Signal.decode.rawValue) at \(line(d)), \(Signal.execute.rawValue) at \(line(e))",
                       Remedy.remoteExec)
        }
        if let (e, o) = near(found[.execute], found[.obfuscation]) {
            return hit("Runs code built from hidden identifiers", .critical,
                       "\(Signal.obfuscation.rawValue) at \(line(o)), \(Signal.execute.rawValue) at \(line(e))",
                       Remedy.remoteExec)
        }
        if let (e, b) = near(found[.execute], found[.encodedBlob]) {
            return hit("Runs an encoded blob", .critical,
                       "\(Signal.encodedBlob.rawValue) at \(line(b)), \(Signal.execute.rawValue) at \(line(e))",
                       Remedy.remoteExec)
        }
        if let (d, env) = near(found[.decode], found[.envSource]) {
            return hit("Decodes an environment variable", .warning,
                       "\(Signal.envSource.rawValue) at \(line(env)), \(Signal.decode.rawValue) at \(line(d))",
                       Remedy.envDecode)
        }
        if let (n, det) = near(found[.network], found[.detach]) {
            return hit("Detaches a process that talks to the network", .warning,
                       "\(Signal.network.rawValue) at \(line(n)), \(Signal.detach.rawValue) at \(line(det))",
                       Remedy.detached)
        }
        if let o = found[.obfuscation]?.first {
            return hit("Identifier hidden from search", .warning,
                       "\(Signal.obfuscation.rawValue) at \(line(o))", Remedy.obfuscated)
        }
        return nil
    }

    // MARK: package.json lifecycle scripts

    static let lifecycleKeys = ["preinstall", "install", "postinstall", "prepare", "prepublish"]
    static let lifecycleRed = ["curl", "wget", "-e ", "--eval", "eval", "base64",
                               "| sh", "|sh", "| bash", "|bash", "chmod +x", "node -"]

    /// A lifecycle script runs on `npm install`, before anybody reads the code.
    static func lifecycleHits(inPackageJSON data: Data) -> [Hit] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else { return [] }
        return lifecycleKeys.compactMap { key in
            guard let body = scripts[key] else { return nil }
            let lower = body.lowercased()
            guard let red = lifecycleRed.first(where: lower.contains) else { return nil }
            return Hit(indicator: "Install script runs code",
                       severity: .critical,
                       evidence: "\(key): \(red.trimmingCharacters(in: .whitespaces))",
                       remediation: Remedy.lifecycle)
        }
    }

    /// node-gyp runs binding.gyp actions during `npm install` with no
    /// lifecycle script to notice, which is what the 2026 worm abused.
    static func bindingGypHit(_ data: Data) -> Hit? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lower = text.lowercased()
        guard lower.contains("'actions'") || lower.contains("\"actions\"") else { return nil }
        guard let red = lifecycleRed.first(where: lower.contains) else { return nil }
        return Hit(indicator: "binding.gyp runs a command at install time",
                   severity: .critical,
                   evidence: "actions with \(red.trimmingCharacters(in: .whitespaces))",
                   remediation: Remedy.bindingGyp)
    }
}
