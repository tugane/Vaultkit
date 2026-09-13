import XCTest
@testable import Vaultkit

/// The licensing service signs in Node and the app verifies in CryptoKit, and
/// nothing in either codebase would notice the two drifting apart until a
/// customer's key stopped working. The fixture below was produced by
/// server/lib/licence.ts's exact signing path.
///
/// Regenerate it with:
///   node server/scripts/keygen.mjs        (for a real release key)
///   swift test --filter CrossLanguage     (to check this pairing still holds)
final class CrossLanguageSignatureTests: XCTestCase {
    private let publicKey = "muN6KKo5nzbc6C3wOrSXPHFNjkvPstiEkPTrLi/1K38="
    private let payload = "eyJrZXkiOiJWSy1BMUIyLUMzRDQtRTVGNi03ODkwIiwibWFjaGluZSI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJlbWFpbCI6ImJ1eWVyQGV4YW1wbGUuY29tIiwicGxhbiI6ImFubnVhbCIsInN0YXR1cyI6ImFjdGl2ZSIsInBlcmlvZEVuZCI6MTgyMDg3NDY5MCwiaXNzdWVkQXQiOjE3ODkzMzg2OTAsInJlY2hlY2tBZnRlciI6MTc4OTk0MzQ5MH0="
    private let signature = "PReMbalSqIVHpnMM3kbcO8aQTH4jsizmWLjJcQQYvZICLAnFWoFk6+GRS8w9+HBcUDzdqv/FKRe+WqDEra5MCw=="

    func testAnEntitlementSignedByTheServiceVerifiesInTheApp() throws {
        let envelope = SignedEnvelope(payload: payload, signature: signature)
        let entitlement = try XCTUnwrap(envelope.open(with: publicKey),
                                        "Node's signature must verify under CryptoKit")

        XCTAssertEqual(entitlement.key, "VK-A1B2-C3D4-E5F6-7890")
        XCTAssertEqual(entitlement.email, "buyer@example.com")
        XCTAssertEqual(entitlement.status, .active)
        XCTAssertEqual(entitlement.machine, String(repeating: "a", count: 64))
        // The dates must survive the seconds-since-epoch round trip the two
        // sides agreed on, not arrive as 1970 or as a decoding failure.
        XCTAssertGreaterThan(entitlement.periodEnd, entitlement.issuedAt)
        XCTAssertEqual(entitlement.periodEnd.timeIntervalSince(entitlement.issuedAt),
                       365 * 86_400, accuracy: 1)
    }

    func testASignatureOverADifferentPayloadIsRejected() throws {
        // Flip one character of the payload: same signature, different message.
        var tampered = Array(payload)
        tampered[10] = tampered[10] == "A" ? "B" : "A"
        let envelope = SignedEnvelope(payload: String(tampered), signature: signature)
        XCTAssertNil(envelope.open(with: publicKey))
    }
}
