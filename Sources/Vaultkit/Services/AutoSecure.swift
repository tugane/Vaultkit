import CoreGraphics
import Foundation

/// What asked for a vault to be closed.
enum SecureTrigger: String, CaseIterable, Equatable {
    case idle, screenLock, sleep, quit

    var label: String {
        switch self {
        case .idle: "gone idle"
        case .screenLock: "the screen locked"
        case .sleep: "the Mac slept"
        case .quit: "Vaultkit quit"
        }
    }
}

/// What one attempt on one vault came to.
enum AutoSecureOutcome: Equatable {
    case secured
    /// Named processes are keeping the volume open. The vault stays mounted.
    case held([String])
    case failed(String)
}

/// One attempt, for the record in Settings. An automatic action nobody can
/// review is indistinguishable from a bug.
struct AutoSecureEvent: Identifiable, Equatable {
    let at: Date
    let org: String
    let trigger: SecureTrigger
    let outcome: AutoSecureOutcome

    var id: String { "\(at.timeIntervalSince1970)-\(org)" }
}

/// When vaults close on their own.
///
/// Mounting is deliberate and ejecting was not: the app shipped with a Secure
/// button and nothing that ever pressed it, so a vault mounted on Monday is
/// still readable on Friday and the dashboard's "exposed right now" count only
/// ever goes up. This closes that, and because the eject itself is the slow,
/// failure-prone part, everything here is kept pure and decided in advance:
/// which vaults, for which trigger, and whether the trigger fires at all.
struct AutoSecurePolicy: Equatable {
    var enabled: Bool
    var idleMinutes: Int
    var onScreenLock: Bool
    var onSleep: Bool
    var onQuit: Bool
    /// Organizations left alone, by `org.name`. Never by `id`: OrgDiscovery
    /// rebuilds every Organization from ~/.gitconfig on each refresh, so `id`
    /// is a fresh UUID every ten seconds.
    var exempt: Set<String>

    /// On by default. A vault that closes itself is the guarantee the app
    /// sells; an hour is long enough that lunch is usually survivable and
    /// short enough that overnight is not.
    static let standard = AutoSecurePolicy(enabled: true, idleMinutes: 60, onScreenLock: true,
                                           onSleep: true, onQuit: true, exempt: [])

    static let idleChoices = [15, 30, 60, 120, 240]

    // MARK: persistence

    private enum Key {
        static let enabled = "vk.autoSecure.enabled"
        static let idle = "vk.autoSecure.idleMinutes"
        static let screenLock = "vk.autoSecure.onScreenLock"
        static let sleep = "vk.autoSecure.onSleep"
        static let quit = "vk.autoSecure.onQuit"
        static let exempt = "vk.autoSecure.exempt"
        /// Set once the user has been told this runs. Existing installs get a
        /// changed machine, so they get told rather than surprised.
        static let announced = "vk.autoSecure.announced"
    }

    static func load(from d: UserDefaults = .standard) -> AutoSecurePolicy {
        AutoSecurePolicy(
            enabled: d.object(forKey: Key.enabled) as? Bool ?? standard.enabled,
            idleMinutes: d.object(forKey: Key.idle) as? Int ?? standard.idleMinutes,
            onScreenLock: d.object(forKey: Key.screenLock) as? Bool ?? standard.onScreenLock,
            onSleep: d.object(forKey: Key.sleep) as? Bool ?? standard.onSleep,
            onQuit: d.object(forKey: Key.quit) as? Bool ?? standard.onQuit,
            exempt: Set(d.object(forKey: Key.exempt) as? [String] ?? [])
        )
    }

    func save(to d: UserDefaults = .standard) {
        d.set(enabled, forKey: Key.enabled)
        d.set(idleMinutes, forKey: Key.idle)
        d.set(onScreenLock, forKey: Key.screenLock)
        d.set(onSleep, forKey: Key.sleep)
        d.set(onQuit, forKey: Key.quit)
        d.set(Array(exempt).sorted(), forKey: Key.exempt)
    }

    static func needsAnnouncing(in d: UserDefaults = .standard) -> Bool {
        !d.bool(forKey: Key.announced)
    }
    static func markAnnounced(in d: UserDefaults = .standard) {
        d.set(true, forKey: Key.announced)
    }

    // MARK: the decision

    func allows(_ trigger: SecureTrigger) -> Bool {
        guard enabled else { return false }
        switch trigger {
        case .idle: return idleMinutes > 0
        case .screenLock: return onScreenLock
        case .sleep: return onSleep
        case .quit: return onQuit
        }
    }

    /// The vaults this trigger should close, right now. Pure, so the whole
    /// decision is testable without a Mac that sleeps.
    ///
    /// `busy` is the app's own in-flight set: a vault being mounted by hand at
    /// the moment the idle timer fires is the user at the keyboard, and racing
    /// them is worse than waiting for the next tick.
    func targets(for trigger: SecureTrigger, idleSeconds: TimeInterval,
                 exposed: [Organization], busy: Set<String>) -> [Organization] {
        guard allows(trigger) else { return [] }
        if trigger == .idle, idleSeconds < TimeInterval(idleMinutes * 60) { return [] }
        return exposed.filter { !exempt.contains($0.name) && !busy.contains($0.name) }
    }
}

/// Seconds since the user last touched this Mac.
enum SystemIdle {
    /// `~0` is the documented "any input event" sentinel. It imports as a valid
    /// CGEventType today, but a force-unwrap on a sentinel is not worth a crash
    /// if that ever changes, so the concrete types stand behind it: the seconds
    /// since the most recent of them is the same number.
    private static let anyInput = CGEventType(rawValue: ~0)

    private static let inputTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .leftMouseDragged, .rightMouseDragged,
        .keyDown, .keyUp, .flagsChanged, .scrollWheel,
    ]

    static func seconds() -> TimeInterval {
        if let anyInput {
            return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        }
        return inputTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }
}
