import Foundation

/// Which events are worth interrupting someone for.
///
/// macOS offers one switch for the whole app, which is too blunt here: the
/// Scanner can be chatty on a big vault, and a user who silences it in System
/// Settings also silences the history-rewrite alarm — the one notification in
/// the app that might mean somebody else is on the machine. So the choice is
/// per event, and the loud one can be turned off without taking the quiet
/// important one with it.
struct NotificationPolicy: Equatable {
    var scannerHits: Bool
    var rewriteRefusals: Bool
    var autoSecure: Bool

    static let standard = NotificationPolicy(scannerHits: true, rewriteRefusals: true, autoSecure: true)

    private enum Key {
        static let scanner = "vk.notify.scannerHits"
        static let rewrites = "vk.notify.rewriteRefusals"
        static let autoSecure = "vk.notify.autoSecure"
        static let lastScanSignature = "vk.notify.lastScanSignature"
    }

    static func load(from d: UserDefaults = .standard) -> NotificationPolicy {
        NotificationPolicy(
            scannerHits: d.object(forKey: Key.scanner) as? Bool ?? standard.scannerHits,
            rewriteRefusals: d.object(forKey: Key.rewrites) as? Bool ?? standard.rewriteRefusals,
            autoSecure: d.object(forKey: Key.autoSecure) as? Bool ?? standard.autoSecure
        )
    }

    func save(to d: UserDefaults = .standard) {
        d.set(scannerHits, forKey: Key.scanner)
        d.set(rewriteRefusals, forKey: Key.rewrites)
        d.set(autoSecure, forKey: Key.autoSecure)
    }

    // MARK: not saying the same thing twice

    /// A stable identity for a set of findings, so an unchanged set can be
    /// recognised across scans.
    ///
    /// The Scanner notified on `!found.isEmpty`, which meant one finding nobody
    /// could fix announced itself every five minutes, forever — and a
    /// notification that arrives on a timer stops being read, including the
    /// time it matters. Findings are identified by what they are and where,
    /// never by a per-run id.
    static func signature(of findings: [ScanFinding]) -> String {
        findings
            .map { "\($0.orgName)/\($0.repo)/\($0.path)#\($0.indicator)" }
            .sorted()
            .joined(separator: "\n")
    }

    /// True when this set of findings has not already been announced. Recording
    /// is the caller's business, so a notification that is switched off does
    /// not silently mark itself as seen.
    static func isNew(_ findings: [ScanFinding], in d: UserDefaults = .standard) -> Bool {
        !findings.isEmpty && signature(of: findings) != d.string(forKey: Key.lastScanSignature)
    }

    static func remember(_ findings: [ScanFinding], in d: UserDefaults = .standard) {
        d.set(signature(of: findings), forKey: Key.lastScanSignature)
    }
}
