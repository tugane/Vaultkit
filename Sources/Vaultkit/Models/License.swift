import Foundation

// MARK: - What a licence covers
//
// Vaultkit is commercial software: fourteen days with everything on, then a
// current subscription. The gate is drawn deliberately, and clause 6 of the
// EULA commits us to it in writing: a lapsed licence NEVER stands between
// someone and their own encrypted data. Mounting, ejecting, removing an
// organization and reading the state of the machine stay available forever.
// Only the cases below are gated, and this enum is the single place that says
// so: if a flow is not listed here, it is free.

enum Feature: String, CaseIterable, Identifiable, Sendable {
    var id: String { rawValue }

    case addOrganization
    case clone
    case scanner
    case activity

    /// Shown on the paywall when a locked control is pressed.
    var label: String {
        switch self {
        case .addOrganization: "Adding an organization"
        case .clone: "Cloning into a vault"
        case .scanner: "The Scanner"
        case .activity: "The Activity view"
        }
    }
}

// MARK: - The service's answer

/// What the licensing service says this machine may do, signed with the
/// Vaultkit release key. The app caches the signed envelope rather than this
/// struct, so a cache edited by hand fails verification instead of granting
/// itself a subscription.
struct Entitlement: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case active         // paid and current
        case pastDue        // payment failed; Stripe is retrying
        case cancelled      // over, or refunded
    }

    var key: String             // the licence key this was issued for
    var machine: String         // the fingerprint it was issued to
    var email: String           // who bought it
    var plan: String            // "annual"
    var status: Status
    var periodEnd: Date         // paid through; a hard ceiling
    var issuedAt: Date          // when the service signed this
    var recheckAfter: Date      // when the app should ask again

    /// The last four characters, for display. A key is a credential: the UI
    /// shows enough to recognise it and never enough to reuse it.
    var maskedKey: String {
        let tail = key.suffix(4)
        return tail.isEmpty ? "····" : "VK-····-\(tail)"
    }
}

// MARK: - The state the UI renders

enum LicenseState: Equatable, Sendable {
    case unknown                            // not read yet
    case trial(daysRemaining: Int)
    case licensed(Entitlement)
    case trialExpired
    case lapsed(Entitlement)                // was paid, no longer current

    /// Everything unlocked?
    var isFull: Bool {
        switch self {
        case .trial, .licensed: true
        case .unknown, .trialExpired, .lapsed: false
        }
    }

    /// True while we are still working out which of the others it is. The UI
    /// must not flash a paywall during launch.
    var isSettled: Bool { self != .unknown }

    func allows(_ feature: Feature) -> Bool { isFull }

    /// One line for the sidebar footer.
    var summary: String {
        switch self {
        case .unknown: "Checking the licence…"
        case .trial(let d): d == 1 ? "Trial · last day" : "Trial · \(d) days left"
        case .licensed(let e):
            e.status == .pastDue ? "Licensed · payment failing" : "Licensed · \(e.maskedKey)"
        case .trialExpired: "Trial over"
        case .lapsed: "Subscription lapsed"
        }
    }

    /// Trials shout near the end; a healthy licence says nothing.
    var deservesABanner: Bool {
        switch self {
        case .trial(let d): d <= 7
        case .licensed(let e): e.status == .pastDue
        case .trialExpired, .lapsed: true
        case .unknown: false
        }
    }
}

// MARK: - Terms, in one place

enum Licensing {
    /// Clause 1.1 of the EULA. Changing this changes the contract.
    static let trialDays = 14
    /// How long a confirmed entitlement is trusted with no network at all.
    /// Long enough for a holiday, short enough that a cancelled card is noticed.
    static let maxOfflineDays = 21
    /// Seats per subscription, mirrored from the server's own check.
    static let seats = 3

    static let purchaseURL = URL(string: "https://vaultkit.app/buy")!
    static let accountURL = URL(string: "https://vaultkit.app/account")!

    /// Overridable so a staging server can be pointed at without a rebuild.
    static var serviceURL: URL {
        if let raw = ProcessInfo.processInfo.environment["VAULTKIT_LICENCE_URL"],
           let url = URL(string: raw) { return url }
        return URL(string: "https://licence.vaultkit.app")!
    }

    /// Ed25519 public half of the release signing key, base64, 32 bytes.
    /// The private half never leaves the licensing service. Replace this with
    /// your own before the first release: scripts/licence-keygen.sh prints both.
    static let signingPublicKey = "REPLACE_ME_WITH_THE_BASE64_ED25519_PUBLIC_KEY="
}

// MARK: - Errors worth showing a human

enum LicenseError: LocalizedError, Equatable {
    case malformedKey
    case rejected(String)           // the service said no, with a reason
    case seatsExhausted(Int)
    case unreachable
    case untrustedResponse          // signature did not verify

    var errorDescription: String? {
        switch self {
        case .malformedKey:
            "That does not look like a Vaultkit licence key. They read VK-XXXX-XXXX-XXXX-XXXX."
        case .rejected(let why): why
        case .seatsExhausted(let n):
            "This licence is already active on \(n) Macs. Free one up in your account, then try again."
        case .unreachable:
            "Could not reach the licensing service. Check your connection and try again."
        case .untrustedResponse:
            "The licensing service returned a response that failed verification. Nothing was changed."
        }
    }
}
