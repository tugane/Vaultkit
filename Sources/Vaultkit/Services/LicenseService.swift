import Foundation

// MARK: - The boundary
//
// Activation is the only thing in Vaultkit that talks to a server of ours, so
// it goes through a protocol like every other system boundary: the tests drive
// the whole licence lifecycle without opening a socket.

protocol LicenseTransporting: Sendable {
    func post(_ path: String, body: [String: String]) async throws -> (status: Int, data: Data)
}

struct HTTPTransport: LicenseTransporting {
    func post(_ path: String, body: [String: String]) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: Licensing.serviceURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Vaultkit/\(VaultkitVersion.current)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Short: a licence check must never make the app feel hung, and every
        // path through it has a working offline answer.
        request.timeoutInterval = 15
        // No cookies, no credential store, no cache: nothing about this request
        // should persist anywhere it could be correlated later.
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

protocol LicenseServing: Sendable {
    func state() async -> LicenseState
    func activate(key: String) async throws -> LicenseState
    func refreshIfDue(force: Bool) async -> LicenseState
    func deactivate() async throws -> LicenseState
}

extension LicenseServing {
    /// The scheduled check. Only Settings' "Check Now" passes force.
    func refreshIfDue() async -> LicenseState { await refreshIfDue(force: false) }
}

// MARK: - The service

final class LicenseService: LicenseServing, @unchecked Sendable {
    private enum Account {
        static let trialStart = "trial.start"
        static let clockSeen = "clock.seen"
        static let entitlement = "entitlement"
    }

    /// A debug run with a fake clock keeps its own keychain items. Without
    /// this, testing the paywall would wind the monotonic guard forward and
    /// leave the developer's real trial reading as expired afterwards.
    private func account(_ name: String) -> String { accountPrefix + name }

    private let store: SecretStoring
    private let transport: LicenseTransporting
    private let machine: String
    private let publicKey: String
    private let now: @Sendable () -> Date
    private let accountPrefix: String

    init(store: SecretStoring = KeychainStore(),
         transport: LicenseTransporting = HTTPTransport(),
         machine: String = MachineFingerprint.current,
         publicKey: String = Licensing.signingPublicKey,
         now: @escaping @Sendable () -> Date = LicenseService.wallClock) {
        self.store = store
        self.transport = transport
        self.machine = machine
        self.publicKey = publicKey
        self.now = now
        #if DEBUG
        self.accountPrefix = ProcessInfo.processInfo.environment["VAULTKIT_FAKE_DAYS"] == nil ? "" : "debug."
        #else
        self.accountPrefix = ""
        #endif
    }

    /// Debug builds honour VAULTKIT_FAKE_DAYS so the trial's last week, its
    /// expiry and the paywall can be seen without waiting a fortnight or
    /// editing the keychain by hand — an item written by another program has
    /// another program's ACL, and the app is then made to prompt for the login
    /// password to read its own licence. Release builds have no such door.
    static let wallClock: @Sendable () -> Date = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["VAULTKIT_FAKE_DAYS"],
           let days = Double(raw) {
            return Date().addingTimeInterval(days * 86_400)
        }
        #endif
        return Date()
    }

    // MARK: Reading the current state

    func state() async -> LicenseState {
        let today = monotonicNow()

        // The trial is anchored on the first read, whatever the answer turns
        // out to be. Someone who buys on day one and cancels on day two would
        // otherwise deactivate their way into a fresh fourteen days, because
        // no anchor was ever written while the licence was doing the talking.
        let trial = trialState(at: today)

        if let entitlement = cachedEntitlement() {
            return judge(entitlement, at: today, fallingBackTo: trial)
        }
        return trial
    }

    /// A clock moved backwards must not resurrect a spent trial, and must not
    /// punish someone who simply corrected a wrong date either. So the latest
    /// moment we have ever seen wins, and nothing is reported to the user.
    private func monotonicNow() -> Date {
        let wall = now()
        let seen = store.read(account(Account.clockSeen))
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))

        let effective = max(wall, seen ?? wall)
        if seen == nil || effective > seen! {
            store.write(Data(String(effective.timeIntervalSince1970).utf8), to: account(Account.clockSeen))
        }
        return effective
    }

    /// Reads the trial anchor, starting one on the very first run.
    private func trialState(at today: Date) -> LicenseState {
        let started: Date
        if let raw = store.read(account(Account.trialStart)),
           let text = String(data: raw, encoding: .utf8),
           let seconds = TimeInterval(text) {
            started = Date(timeIntervalSince1970: seconds)
        } else {
            started = today
            store.write(Data(String(today.timeIntervalSince1970).utf8), to: account(Account.trialStart))
        }

        let elapsed = today.timeIntervalSince(started)
        let remaining = Licensing.trialDays - Int(floor(elapsed / 86_400))
        return remaining > 0 ? .trial(daysRemaining: remaining) : .trialExpired
    }

    /// Turns a verified entitlement into a state, applying the three ceilings
    /// that hold with no network: the paid period, the offline budget, and the
    /// subscription's own status.
    private func judge(_ entitlement: Entitlement, at today: Date,
                       fallingBackTo trial: LicenseState) -> LicenseState {
        guard entitlement.machine == machine else { return trial }

        let offlineFor = today.timeIntervalSince(entitlement.issuedAt)
        let staleBeyondGrace = offlineFor > Double(Licensing.maxOfflineDays) * 86_400

        switch entitlement.status {
        case .cancelled:
            return .lapsed(entitlement)
        case .active, .pastDue:
            if today > entitlement.periodEnd { return .lapsed(entitlement) }
            if staleBeyondGrace { return .lapsed(entitlement) }
            return .licensed(entitlement)
        }
    }

    private func cachedEntitlement() -> Entitlement? {
        guard let raw = store.read(account(Account.entitlement)),
              let envelope = try? JSONDecoder().decode(SignedEnvelope.self, from: raw)
        else { return nil }
        // A cache that fails verification is a cache someone edited. Drop it
        // and fall back to the trial rather than trusting it.
        guard let entitlement = envelope.open(with: publicKey) else {
            store.delete(account(Account.entitlement))
            return nil
        }
        return entitlement
    }

    // MARK: Activation

    func activate(key: String) async throws -> LicenseState {
        let key = Self.normalise(key)
        guard Self.looksLikeAKey(key) else { throw LicenseError.malformedKey }

        let envelope = try await call("v1/activate", [
            "key": key,
            "machine": machine,
            "label": MachineFingerprint.label,
            "version": VaultkitVersion.current
        ])
        store.write(envelope, to: account(Account.entitlement))
        return await state()
    }

    /// Re-confirms with the service when the entitlement says it is due, and
    /// only then. Called at launch and daily; a no-op the rest of the time, so
    /// the app is silent on the network for a week at a stretch.
    ///
    /// `force` is the user asking in Settings. Nothing else sets it: an app
    /// that revalidates whenever it feels like it is an app that stops working
    /// on a train.
    func refreshIfDue(force: Bool) async -> LicenseState {
        let current = await state()
        guard case .licensed(let entitlement) = current else { return current }
        guard force || monotonicNow() >= entitlement.recheckAfter else { return current }

        // Offline is not a verdict. The entitlement still has its grace budget,
        // and judge() is what decides when that runs out.
        guard let envelope = try? await call("v1/validate", [
            "key": entitlement.key,
            "machine": machine,
            "version": VaultkitVersion.current
        ]) else { return current }

        store.write(envelope, to: account(Account.entitlement))
        return await state()
    }

    /// Frees this Mac's seat so it can be used on another. The local side
    /// happens either way: someone wiping a Mac they are about to sell must not
    /// be left licensed on it because the service was unreachable.
    func deactivate() async throws -> LicenseState {
        let key: String? = switch await state() {
        case .licensed(let e): e.key
        case .lapsed(let e): e.key
        default: nil
        }
        if let key {
            _ = try? await post("v1/deactivate", ["key": key, "machine": machine])
        }
        store.delete(account(Account.entitlement))
        return await state()
    }

    // MARK: Talking to the service

    /// Posts, maps the failure modes onto something a human can act on, and
    /// returns the raw signed envelope for storing. The envelope is verified
    /// here before it is ever written, so a compromised service still cannot
    /// hand this app an entitlement it did not sign.
    private func post(_ path: String, _ body: [String: String]) async throws -> Data {
        let status: Int, data: Data
        do {
            (status, data) = try await transport.post(path, body: body)
        } catch {
            throw LicenseError.unreachable
        }

        guard status == 200 else {
            let failure = try? JSONDecoder().decode(ServiceError.self, from: data)
            if failure?.code == "seats_exhausted" {
                throw LicenseError.seatsExhausted(failure?.seats ?? Licensing.seats)
            }
            throw LicenseError.rejected(failure?.error ?? "The licensing service refused that key (HTTP \(status)).")
        }
        return data
    }

    /// As `post`, but the response must be an entitlement this app can verify,
    /// issued to this machine. A compromised service, or a proxy terminating
    /// TLS, still cannot hand Vaultkit a licence it did not sign.
    private func call(_ path: String, _ body: [String: String]) async throws -> Data {
        let data = try await post(path, body)
        guard let envelope = try? JSONDecoder().decode(SignedEnvelope.self, from: data),
              let entitlement = envelope.open(with: publicKey),
              entitlement.machine == machine
        else { throw LicenseError.untrustedResponse }
        return data
    }

    private struct ServiceError: Decodable {
        let error: String?
        let code: String?
        let seats: Int?
    }

    // MARK: Key hygiene

    /// Accepts what people actually paste: lowercase, spaced, wrapped in
    /// quotes by a mail client, with or without the hyphens.
    static func normalise(_ raw: String) -> String {
        let kept = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard kept.hasPrefix("VK") else { return raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

        let body = Array(kept.dropFirst(2))
        let groups = stride(from: 0, to: body.count, by: 4).map { String(body[$0..<min($0 + 4, body.count)]) }
        return (["VK"] + groups).joined(separator: "-")
    }

    static func looksLikeAKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-")
        guard parts.count == 5, parts[0] == "VK" else { return false }
        return parts.dropFirst().allSatisfy { part in
            part.count == 4 && part.allSatisfy { $0.isLetter || $0.isNumber }
        }
    }
}
