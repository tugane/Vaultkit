import Foundation
import CryptoKit

// MARK: - Acting on a hit
//
// The Scanner finds; this acts. Two rules make it safe to run unattended:
//
//  1. Nothing is destroyed. A cleaned file's original and a moved file both
//     land in the org's quarantine, inside that org's vault — encrypted at
//     rest, never outside the compartment — under a neutralized name, with a
//     record beside them. Restore and purge are both explicit.
//  2. A config file keeps working. The loader is *appended* after the real
//     config, so cleaning truncates at the injection line and keeps what was
//     there. Deleting postcss.config.mjs would just break the build.

enum QuarantineError: LocalizedError {
    case noInjectionPoint
    case invalidResult(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .noInjectionPoint: "No injection line found to cut at; quarantined the whole file instead."
        case .invalidResult(let what): "The edited \(what) did not parse; left untouched."
        case .missing(let path): "\(path) is no longer there."
        }
    }
}

struct QuarantineService {
    static let folder = ".vaultkit/quarantine"

    /// Where the legitimate content ends: the earliest of these in a file.
    static let injectionMarkers = [
        "global['!']", "global['_V']", "global['r'] = require", "var _$_1e42",
        "function MDy(", "rmcej%otb%", "Cot%3t=shtP",
    ]

    private let fm = FileManager.default

    // MARK: remediate

    /// Apply the finding's fix. Returns what happened, and the quarantine
    /// record when bytes were set aside.
    func remediate(_ f: ScanFinding, vaultRoot: String) throws -> (ActionEvent, QuarantineItem?) {
        let absolute = vaultRoot + "/" + f.path
        guard fm.fileExists(atPath: absolute) else { throw QuarantineError.missing(f.path) }

        switch f.fix {
        case .clean:
            do { return try clean(f, at: absolute, vaultRoot: vaultRoot) }
            catch QuarantineError.noInjectionPoint { return try move(f, at: absolute, vaultRoot: vaultRoot) }

        case .quarantine:
            return try move(f, at: absolute, vaultRoot: vaultRoot)

        case .dropDependency(let name):
            return try dropDependency(name, f, at: absolute, vaultRoot: vaultRoot)

        case .dropGitignoreLine:
            let text = try String(contentsOfFile: absolute, encoding: .utf8)
            let kept = text.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces) != "config.bat" }
                .joined(separator: "\n")
            try kept.write(toFile: absolute, atomically: true, encoding: .utf8)
            return (ActionEvent(date: Date(), kind: .cleaned, orgName: f.orgName, path: f.path,
                                indicator: f.indicator, detail: "Removed the config.bat line."), nil)

        case .manual:
            return (ActionEvent(date: Date(), kind: .manual, orgName: f.orgName, path: f.path,
                                indicator: f.indicator, detail: "No automatic fix for this kind of hit."), nil)
        }
    }

    /// Truncate at the first injection line, keep everything before it.
    private func clean(_ f: ScanFinding, at absolute: String, vaultRoot: String) throws -> (ActionEvent, QuarantineItem?) {
        let data = try Data(contentsOf: URL(fileURLWithPath: absolute))
        guard let cut = Self.injectionOffset(in: data), cut > 0 else { throw QuarantineError.noInjectionPoint }

        var kept = data.prefix(cut)
        while let last = kept.last, last == 0x0A || last == 0x0D || last == 0x20 || last == 0x09 { kept.removeLast() }
        kept.append(0x0A)

        let item = try stash(data: data, originalPath: f.path, name: (absolute as NSString).lastPathComponent,
                             finding: f, kind: .cleaned, vaultRoot: vaultRoot)
        let attrs = try? fm.attributesOfItem(atPath: absolute)
        try kept.write(to: URL(fileURLWithPath: absolute), options: .atomic)
        if let perms = attrs?[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: absolute)
        }
        let removed = data.count - kept.count
        return (ActionEvent(date: Date(), kind: .cleaned, orgName: f.orgName, path: f.path,
                            indicator: f.indicator,
                            detail: "Cut \(removed) appended bytes, kept \(kept.count) bytes of the real file. Original in quarantine.",
                            quarantineID: item.id), item)
    }

    /// Byte offset of the start of the line holding the earliest marker.
    static func injectionOffset(in data: Data) -> Int? {
        var earliest: Int? = nil
        for marker in injectionMarkers {
            if let r = data.range(of: Data(marker.utf8)) {
                earliest = min(earliest ?? r.lowerBound, r.lowerBound)
            }
        }
        guard let hit = earliest else { return nil }
        // Back up to the start of that line.
        var i = hit
        while i > 0, data[i - 1] != 0x0A { i -= 1 }
        return i
    }

    /// Move a file or directory whole into quarantine.
    private func move(_ f: ScanFinding, at absolute: String, vaultRoot: String) throws -> (ActionEvent, QuarantineItem?) {
        var isDir: ObjCBool = false
        fm.fileExists(atPath: absolute, isDirectory: &isDir)
        let bytes = isDir.boolValue ? Data() : (try? Data(contentsOf: URL(fileURLWithPath: absolute))) ?? Data()
        let name = (absolute as NSString).lastPathComponent
        let (dir, item) = try record(originalPath: f.path, finding: f, kind: .quarantined,
                                     sha: isDir.boolValue ? "" : Self.sha256(bytes),
                                     size: isDir.boolValue ? Self.directorySize(absolute) : bytes.count,
                                     vaultRoot: vaultRoot)
        try fm.moveItem(atPath: absolute, toPath: dir + "/" + name + ".quarantined")
        return (ActionEvent(date: Date(), kind: .quarantined, orgName: f.orgName, path: f.path,
                            indicator: f.indicator,
                            detail: isDir.boolValue ? "Moved the directory into quarantine." : "Moved the file into quarantine (\(bytes.count) bytes).",
                            quarantineID: item.id), item)
    }

    /// Remove one package line from package.json without reformatting the
    /// rest. The result must still parse, or nothing is written.
    private func dropDependency(_ name: String, _ f: ScanFinding, at absolute: String,
                                vaultRoot: String) throws -> (ActionEvent, QuarantineItem?) {
        let original = try String(contentsOfFile: absolute, encoding: .utf8)
        var lines = original.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { $0.contains("\"\(name)\"") && $0.contains(":") }) else {
            throw QuarantineError.invalidResult("package.json")
        }
        let removedHadComma = lines[idx].trimmingCharacters(in: .whitespaces).hasSuffix(",")
        lines.remove(at: idx)
        if !removedHadComma {
            // It was the section's last entry: the previous entry's comma must go too.
            var j = idx - 1
            while j >= 0, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j -= 1 }
            if j >= 0, lines[j].trimmingCharacters(in: .whitespaces).hasSuffix(",") {
                if let comma = lines[j].lastIndex(of: ",") { lines[j].remove(at: comma) }
            }
        }
        let edited = lines.joined(separator: "\n")
        guard let data = edited.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw QuarantineError.invalidResult("package.json")
        }
        let item = try stash(data: Data(original.utf8), originalPath: f.path, name: "package.json",
                             finding: f, kind: .cleaned, vaultRoot: vaultRoot)
        try edited.write(toFile: absolute, atomically: true, encoding: .utf8)
        return (ActionEvent(date: Date(), kind: .cleaned, orgName: f.orgName, path: f.path,
                            indicator: f.indicator,
                            detail: "Removed \"\(name)\" from package.json. Original in quarantine; delete node_modules and the lockfile entry.",
                            quarantineID: item.id), item)
    }

    // MARK: quarantine store

    private func stash(data: Data, originalPath: String, name: String, finding: ScanFinding,
                       kind: ActionEvent.Kind, vaultRoot: String) throws -> QuarantineItem {
        let (dir, item) = try record(originalPath: originalPath, finding: finding, kind: kind,
                                     sha: Self.sha256(data), size: data.count, vaultRoot: vaultRoot)
        try data.write(to: URL(fileURLWithPath: dir + "/" + name + ".quarantined"), options: .atomic)
        return item
    }

    private func record(originalPath: String, finding: ScanFinding, kind: ActionEvent.Kind,
                        sha: String, size: Int, vaultRoot: String) throws -> (String, QuarantineItem) {
        let stamp = Self.stampFormatter.string(from: Date())
        let id = "\(stamp)-\(String(UUID().uuidString.prefix(4)).lowercased())"
        let dir = "\(vaultRoot)/\(Self.folder)/\(id)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let item = QuarantineItem(id: id, orgName: finding.orgName, originalPath: originalPath,
                                  indicator: finding.indicator, evidence: finding.evidence,
                                  date: Date(), kind: kind, sha256: sha, bytes: size)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(item).write(to: URL(fileURLWithPath: dir + "/record.json"), options: .atomic)
        return (dir, item)
    }

    /// Everything currently held for one vault, newest first.
    func items(in vaultRoot: String) -> [QuarantineItem] {
        let base = "\(vaultRoot)/\(Self.folder)"
        guard let ids = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return ids.compactMap { id -> QuarantineItem? in
            guard let data = fm.contents(atPath: "\(base)/\(id)/record.json") else { return nil }
            return try? decoder.decode(QuarantineItem.self, from: data)
        }.sorted { $0.date > $1.date }
    }

    /// Put the held bytes back where they came from, replacing whatever is
    /// there now (for a cleaned file, that is the cleaned version).
    func restore(_ item: QuarantineItem, vaultRoot: String) throws -> ActionEvent {
        let dir = "\(vaultRoot)/\(Self.folder)/\(item.id)"
        guard let held = (try? fm.contentsOfDirectory(atPath: dir))?.first(where: { $0.hasSuffix(".quarantined") }) else {
            throw QuarantineError.missing(item.id)
        }
        let destination = vaultRoot + "/" + item.originalPath
        try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination) { try fm.removeItem(atPath: destination) }
        try fm.moveItem(atPath: dir + "/" + held, toPath: destination)
        try fm.removeItem(atPath: dir)
        return ActionEvent(date: Date(), kind: .restored, orgName: item.orgName, path: item.originalPath,
                           indicator: item.indicator, detail: "Restored from quarantine \(item.id).",
                           quarantineID: item.id)
    }

    /// Discard the held bytes for good.
    func purge(_ item: QuarantineItem, vaultRoot: String) throws -> ActionEvent {
        try fm.removeItem(atPath: "\(vaultRoot)/\(Self.folder)/\(item.id)")
        return ActionEvent(date: Date(), kind: .purged, orgName: item.orgName, path: item.originalPath,
                           indicator: item.indicator, detail: "Purged quarantine \(item.id).",
                           quarantineID: item.id)
    }

    // MARK: helpers

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func directorySize(_ path: String) -> Int {
        guard let e = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total = 0
        for case let rel as String in e {
            total += (try? FileManager.default.attributesOfItem(atPath: path + "/" + rel))?[.size] as? Int ?? 0
        }
        return total
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - History
//
// The one file Vaultkit owns besides nothing: what the Scanner did and when.
// Contains org names, repo-relative paths and indicator names — no secrets,
// no file contents.

struct HistoryStore {
    let url: URL

    init(url: URL? = nil) {
        if let url { self.url = url; return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.url = support.appendingPathComponent("Vaultkit/scanner-history.json")
    }

    func load() -> ScannerHistory {
        guard let data = try? Data(contentsOf: url) else { return ScannerHistory() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ScannerHistory.self, from: data)) ?? ScannerHistory()
    }

    func save(_ history: ScannerHistory) {
        var trimmed = history
        trimmed.scans = Array(trimmed.scans.prefix(200))
        trimmed.actions = Array(trimmed.actions.prefix(500))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(trimmed).write(to: url, options: .atomic)
    }
}
