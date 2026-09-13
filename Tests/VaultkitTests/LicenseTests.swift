import XCTest
import CryptoKit
@testable import Vaultkit

/// The licence is the one part of Vaultkit that can refuse to work, so it is
/// tested the way the Scanner is: against a fake service and a fake clock,
/// with real signatures, so the failure modes that matter (an edited cache, a
/// wound-back clock, a seat on another Mac, no network at all) are exercised
/// rather than assumed.
final class LicenseTests: XCTestCase {

    // MARK: - A signing key that only these tests hold

    private let signingKey = Curve25519.Signing.PrivateKey()
    private var publicKey: String { signingKey.publicKey.rawRepresentation.base64EncodedString() }

    private let thisMac = "fingerprint-of-this-mac"
    private let day: TimeInterval = 86_400

    private func envelope(machine: String? = nil,
                          status: Entitlement.Status = .active,
                          periodEnd: Date,
                          issuedAt: Date,
                          recheckAfter: Date? = nil,
                          signedBy key: Curve25519.Signing.PrivateKey? = nil) -> Data {
        let entitlement = Entitlement(
            key: "VK-A1B2-C3D4-E5F6-7890",
            machine: machine ?? thisMac,
            email: "buyer@example.com",
            plan: "annual",
            status: status,
            periodEnd: periodEnd,
            issuedAt: issuedAt,
            recheckAfter: recheckAfter ?? issuedAt.addingTimeInterval(7 * day)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let payload = try! encoder.encode(entitlement).base64EncodedString()
        let signature = try! (key ?? signingKey).signature(for: Data(payload.utf8))
        return try! JSONEncoder().encode(
            SignedEnvelope(payload: payload, signature: signature.base64EncodedString())
        )
    }

    /// A service that answers every call with the same canned body.
    private struct FakeTransport: LicenseTransporting {
        let status: Int
        let body: Data
        let record: (@Sendable (String, [String: String]) -> Void)?

        init(status: Int = 200, body: Data = Data(),
             record: (@Sendable (String, [String: String]) -> Void)? = nil) {
            self.status = status
            self.body = body
            self.record = record
        }

        func post(_ path: String, body sent: [String: String]) async throws -> (status: Int, data: Data) {
            record?(path, sent)
            return (status, body)
        }
    }

    private struct DeadTransport: LicenseTransporting {
        struct Offline: Error {}
        func post(_ path: String, body: [String: String]) async throws -> (status: Int, data: Data) {
            throw Offline()
        }
    }

    private func service(store: SecretStoring,
                         transport: LicenseTransporting = DeadTransport(),
                         at date: Date) -> LicenseService {
        LicenseService(store: store, transport: transport, machine: thisMac,
                       publicKey: publicKey, now: { date })
    }

    // MARK: - The trial

    func testFirstRunStartsAFourteenDayTrial() async {
        let store = MemorySecretStore()
        let state = await service(store: store, at: Date()).state()
        XCTAssertEqual(state, .trial(daysRemaining: 14))
        XCTAssertTrue(state.isFull)
    }

    func testTheTrialCountsDownAndThenEnds() async {
        let store = MemorySecretStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await service(store: store, at: start).state()

        let onDayEight = await service(store: store, at: start.addingTimeInterval(7 * day)).state()
        XCTAssertEqual(onDayEight, .trial(daysRemaining: 7))

        let lastMoment = await service(store: store, at: start.addingTimeInterval(14 * day - 1)).state()
        XCTAssertEqual(lastMoment, .trial(daysRemaining: 1))

        let over = await service(store: store, at: start.addingTimeInterval(14 * day)).state()
        XCTAssertEqual(over, .trialExpired)
        XCTAssertFalse(over.isFull)
    }

    /// Winding the clock back is the oldest way to extend a trial. The latest
    /// moment ever seen wins, so a spent trial stays spent.
    func testAWoundBackClockDoesNotResurrectTheTrial() async {
        let store = MemorySecretStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await service(store: store, at: start).state()
        _ = await service(store: store, at: start.addingTimeInterval(20 * day)).state()

        let cheated = await service(store: store, at: start.addingTimeInterval(day)).state()
        XCTAssertEqual(cheated, .trialExpired)
    }

    /// Deleting the app does not reset it either: the anchor is in the
    /// keychain, which outlives the bundle. Modelled here as a store that
    /// survives while the service does not.
    func testTheTrialSurvivesAReinstall() async {
        let keychain = MemorySecretStore()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await service(store: keychain, at: start).state()

        let afterReinstall = await service(store: keychain, at: start.addingTimeInterval(10 * day)).state()
        XCTAssertEqual(afterReinstall, .trial(daysRemaining: 4))
    }

    // MARK: - Activation

    func testActivationStoresAVerifiedEntitlement() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var sent: [String: String] = [:]
        let transport = FakeTransport(
            body: envelope(periodEnd: now.addingTimeInterval(365 * day), issuedAt: now),
            record: { _, body in sent = body }
        )
        let store = MemorySecretStore()
        let subject = service(store: store, transport: transport, at: now)

        let state = try await subject.activate(key: "vk a1b2 c3d4 e5f6 7890")
        guard case .licensed(let entitlement) = state else { return XCTFail("expected a licence, got \(state)") }
        XCTAssertEqual(entitlement.email, "buyer@example.com")
        XCTAssertEqual(entitlement.maskedKey, "VK-····-7890")

        // PRIVACY.md lists exactly these four fields, and no others.
        XCTAssertEqual(Set(sent.keys), ["key", "machine", "label", "version"])
        XCTAssertEqual(sent["key"], "VK-A1B2-C3D4-E5F6-7890")
        XCTAssertEqual(sent["machine"], thisMac)
    }

    func testAMalformedKeyNeverReachesTheNetwork() async {
        let store = MemorySecretStore()
        let transport = FakeTransport(status: 500, body: Data())
        do {
            _ = try await service(store: store, transport: transport, at: Date()).activate(key: "hello")
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error as? LicenseError, .malformedKey)
        }
    }

    func testAnExhaustedSeatIsReportedAsSuch() async {
        let body = Data(#"{"error":"no seats","code":"seats_exhausted","seats":3}"#.utf8)
        let transport = FakeTransport(status: 409, body: body)
        do {
            _ = try await service(store: MemorySecretStore(), transport: transport, at: Date())
                .activate(key: "VK-A1B2-C3D4-E5F6-7890")
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error as? LicenseError, .seatsExhausted(3))
        }
    }

    /// A service that has been compromised, or a proxy terminating TLS, still
    /// cannot mint an entitlement: the signature is checked before the response
    /// is written anywhere.
    func testAnEntitlementSignedByTheWrongKeyIsRefused() async {
        let now = Date()
        let impostor = Curve25519.Signing.PrivateKey()
        let transport = FakeTransport(
            body: envelope(periodEnd: now.addingTimeInterval(365 * day), issuedAt: now, signedBy: impostor)
        )
        let store = MemorySecretStore()
        do {
            _ = try await service(store: store, transport: transport, at: now)
                .activate(key: "VK-A1B2-C3D4-E5F6-7890")
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error as? LicenseError, .untrustedResponse)
        }
        XCTAssertNil(store.read("entitlement"), "nothing should have been cached")
    }

    func testAnEntitlementForAnotherMachineIsRefused() async {
        let now = Date()
        let transport = FakeTransport(
            body: envelope(machine: "someone-elses-mac",
                           periodEnd: now.addingTimeInterval(365 * day), issuedAt: now)
        )
        do {
            _ = try await service(store: MemorySecretStore(), transport: transport, at: now)
                .activate(key: "VK-A1B2-C3D4-E5F6-7890")
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error as? LicenseError, .untrustedResponse)
        }
    }

    func testAnUnreachableServiceIsNotAVerdict() async {
        do {
            _ = try await service(store: MemorySecretStore(), at: Date())
                .activate(key: "VK-A1B2-C3D4-E5F6-7890")
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error as? LicenseError, .unreachable)
        }
    }

    // MARK: - Living with a cached entitlement

    func testACachedLicenceWorksWithNoNetworkAtAll() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = MemorySecretStore([
            "entitlement": envelope(periodEnd: now.addingTimeInterval(300 * day), issuedAt: now)
        ])
        // Eight days on: past the re-check date, still inside the offline budget.
        let later = now.addingTimeInterval(8 * day)
        let state = await service(store: store, at: later).refreshIfDue()
        XCTAssertTrue(state.isFull, "a failed re-check must not revoke a live licence")
    }

    func testTheOfflineBudgetEventuallyRunsOut() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = MemorySecretStore([
            "entitlement": envelope(periodEnd: now.addingTimeInterval(300 * day), issuedAt: now)
        ])
        let wayLater = now.addingTimeInterval(Double(Licensing.maxOfflineDays + 1) * day)
        let state = await service(store: store, at: wayLater).state()
        guard case .lapsed = state else { return XCTFail("expected a lapse, got \(state)") }
    }

    func testAPaidPeriodThatHasEndedLapses() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = MemorySecretStore([
            "entitlement": envelope(periodEnd: now.addingTimeInterval(-day), issuedAt: now)
        ])
        let state = await service(store: store, at: now).state()
        guard case .lapsed = state else { return XCTFail("expected a lapse, got \(state)") }
    }

    func testACancelledSubscriptionLapsesEvenInsideThePaidPeriod() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = MemorySecretStore([
            "entitlement": envelope(status: .cancelled,
                                    periodEnd: now.addingTimeInterval(300 * day), issuedAt: now)
        ])
        let state = await service(store: store, at: now).state()
        guard case .lapsed = state else { return XCTFail("expected a lapse, got \(state)") }
    }

    /// Stripe retries a failed card for days. Cutting someone off on the first
    /// failure would lock a security tool over a expired card.
    func testAFailingPaymentKeepsWorkingWhileStripeRetries() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = MemorySecretStore([
            "entitlement": envelope(status: .pastDue,
                                    periodEnd: now.addingTimeInterval(30 * day), issuedAt: now)
        ])
        let state = await service(store: store, at: now).state()
        XCTAssertTrue(state.isFull)
        XCTAssertTrue(state.deservesABanner, "but it must say so")
    }

    func testAnEditedCacheIsDiscardedRatherThanTrusted() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var raw = envelope(periodEnd: now.addingTimeInterval(-day), issuedAt: now)
        // Re-encode with a periodEnd a decade out, leaving the signature alone:
        // exactly what editing the keychain item by hand would produce.
        var decoded = try! JSONDecoder().decode(SignedEnvelope.self, from: raw)
        let forged = Entitlement(key: "VK-A1B2-C3D4-E5F6-7890", machine: thisMac,
                                 email: "buyer@example.com", plan: "annual", status: .active,
                                 periodEnd: now.addingTimeInterval(3650 * day),
                                 issuedAt: now, recheckAfter: now.addingTimeInterval(3650 * day))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoded = SignedEnvelope(payload: try! encoder.encode(forged).base64EncodedString(),
                                 signature: decoded.signature)
        raw = try! JSONEncoder().encode(decoded)

        let store = MemorySecretStore(["entitlement": raw])
        let state = await service(store: store, at: now).state()
        XCTAssertEqual(state, .trial(daysRemaining: 14), "falls back to a trial, not to a licence")
        XCTAssertNil(store.read("entitlement"), "and the bad cache is dropped")
    }

    func testDeactivationReleasesTheSeatAndForgetsTheLicence() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = MemorySecretStore([
            "trial.start": Data(String(now.timeIntervalSince1970 - 60 * day).utf8),
            "entitlement": envelope(periodEnd: now.addingTimeInterval(300 * day), issuedAt: now)
        ])
        var paths: [String] = []
        let transport = FakeTransport(body: Data("{}".utf8), record: { path, _ in paths.append(path) })

        let state = try await service(store: store, transport: transport, at: now).deactivate()
        XCTAssertEqual(paths, ["v1/deactivate"])
        XCTAssertNil(store.read("entitlement"))
        XCTAssertEqual(state, .trialExpired, "the trial is not handed back either")
    }

    /// Buying on day one must still burn the trial, or cancelling and
    /// deactivating would hand out a second one.
    func testActivatingImmediatelyStillStartsTheTrialClock() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = MemorySecretStore()
        let transport = FakeTransport(
            body: envelope(periodEnd: now.addingTimeInterval(365 * day), issuedAt: now)
        )
        _ = try await service(store: store, transport: transport, at: now)
            .activate(key: "VK-A1B2-C3D4-E5F6-7890")

        // A month later, having cancelled: the trial is long gone.
        let after = now.addingTimeInterval(30 * day)
        let store2 = MemorySecretStore(["trial.start": store.read("trial.start")!])
        let state = await service(store: store2, at: after).state()
        XCTAssertEqual(state, .trialExpired)
    }

    // MARK: - What the gate covers

    /// Clause 6 of the EULA in executable form. If a future change adds a case
    /// to Feature for mounting, ejecting or removing, this fails.
    func testTheGateNeverCoversReachingYourOwnData() {
        let gated = Set(Feature.allCases.map(\.rawValue))
        for forbidden in ["mount", "eject", "unmount", "relocate", "remove", "removeOrganization", "doctor"] {
            XCTAssertFalse(gated.contains(forbidden),
                           "\(forbidden) must never require a licence: see clause 6 of LICENSE")
        }
    }

    func testALapsedLicenceAllowsNothingGatedAndATrialAllowsEverything() {
        for feature in Feature.allCases {
            XCTAssertTrue(LicenseState.trial(daysRemaining: 1).allows(feature))
            XCTAssertFalse(LicenseState.trialExpired.allows(feature))
            XCTAssertFalse(LicenseState.unknown.allows(feature),
                           "an unread licence must not unlock anything at launch")
        }
    }

    // MARK: - Keys as people actually paste them

    func testKeysAreNormalisedTheWayPeoplePasteThem() {
        let canonical = "VK-A1B2-C3D4-E5F6-7890"
        for typed in ["VK-A1B2-C3D4-E5F6-7890",
                      "vk-a1b2-c3d4-e5f6-7890",
                      "vk a1b2 c3d4 e5f6 7890",
                      "VKA1B2C3D4E5F67890",
                      "  VK-A1B2-C3D4-E5F6-7890  "] {
            XCTAssertEqual(LicenseService.normalise(typed), canonical, "from \(typed)")
            XCTAssertTrue(LicenseService.looksLikeAKey(LicenseService.normalise(typed)))
        }

        for nonsense in ["", "hello", "VK-A1B2", "VK-A1B2-C3D4-E5F6-7890-1234"] {
            XCTAssertFalse(LicenseService.looksLikeAKey(LicenseService.normalise(nonsense)))
        }
    }
}
