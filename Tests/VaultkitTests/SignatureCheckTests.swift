import XCTest
@testable import Vaultkit

/// git reports one letter, "B", for two unrelated events. The fixtures below
/// are the real thing: two commits from the same repository, signed by the same
/// Secure Enclave key minutes apart, one of which the provider failed to sign
/// while still emitting a well-formed envelope. Telling them apart is the whole
/// point of the check, so they are pinned here byte for byte.
final class SignatureCheckTests: XCTestCase {

    /// The provider signed nothing: eight zero bytes where a P-256 (r, s) pair
    /// of about seventy belongs. Everything around them parses perfectly.
    private let signedNothing = """
    -----BEGIN SSH SIGNATURE-----
    U1NIU0lHAAAAAQAAAH8AAAAic2stZWNkc2Etc2hhMi1uaXN0cDI1NkBvcGVuc3NoLmNvbQ
    AAAAhuaXN0cDI1NgAAAEEEWML8lRit/gYxxUeBD7l3Jb2LlfVrKBpuyd1U1mWYruppR8AX
    Fs/yXsr9Lu8IQ+0YqzJi4WK6RQh7hQuxhEzojgAAAARzc2g6AAAAA2dpdAAAAAAAAAAGc2
    hhNTEyAAAANwAAACJzay1lY2RzYS1zaGEyLW5pc3RwMjU2QG9wZW5zc2guY29tAAAACAAA
    AAAAAAAAIQAAAAE=
    -----END SSH SIGNATURE-----
    """

    /// The same key, working. Present here to prove the classifier keys on the
    /// signature bytes and not on anything incidental to the failing one.
    private let complete = """
    -----BEGIN SSH SIGNATURE-----
    U1NIU0lHAAAAAQAAAH8AAAAic2stZWNkc2Etc2hhMi1uaXN0cDI1NkBvcGVuc3NoLmNvbQ
    AAAAhuaXN0cDI1NgAAAEEEWML8lRit/gYxxUeBD7l3Jb2LlfVrKBpuyd1U1mWYruppR8AX
    Fs/yXsr9Lu8IQ+0YqzJi4WK6RQh7hQuxhEzojgAAAARzc2g6AAAAA2dpdAAAAAAAAAAGc2
    hhNTEyAAAAeAAAACJzay1lY2RzYS1zaGEyLW5pc3RwMjU2QG9wZW5zc2guY29tAAAASQAA
    ACAhX8BoqO2rD5R5z/oMse31czSQPX1C5oqOBOjq3Cn17QAAACEA9s7+ZgCPoGG8Pb3E/V
    jpGgUORTqpfhEMK2eq4Hh3A5MhAAAAAQ==
    -----END SSH SIGNATURE-----
    """

    // MARK: classification

    func testEmptySignatureIsNotTampering() {
        XCTAssertEqual(DoctorService.fault(inSignatureBlock: signedNothing), .emptySignature,
                       "an envelope with no signature bytes is a provider failure, not an altered commit")
    }

    /// The classifier never verifies: git already did that and said "B". Given
    /// real signature bytes, the only remaining explanation is that they are
    /// over different content.
    func testCompleteSignatureBytesMeanMismatch() {
        XCTAssertEqual(DoctorService.fault(inSignatureBlock: complete), .mismatch)
    }

    func testForeignAndDamagedBlocksAreNotGuessedAt() {
        let pgp = "-----BEGIN PGP SIGNATURE-----\niQIzBAABCgAdFiEE\n-----END PGP SIGNATURE-----"
        XCTAssertEqual(DoctorService.fault(inSignatureBlock: pgp), .unclassified,
                       "a PGP-signed commit must not be reported as tampering")
        XCTAssertEqual(DoctorService.fault(inSignatureBlock: "-----BEGIN SSH SIGNATURE-----\nnot base64 !!\n-----END SSH SIGNATURE-----"),
                       .unclassified)

        // Truncated mid-field: a length prefix that runs past the end must fail
        // closed rather than read whatever follows in memory.
        let truncated = "-----BEGIN SSH SIGNATURE-----\n" + String(signedNothing
            .split(separator: "\n").dropFirst().dropLast().joined().prefix(40)) + "\n-----END SSH SIGNATURE-----"
        XCTAssertEqual(DoctorService.fault(inSignatureBlock: truncated), .unclassified)
    }

    // MARK: raw commit parsing

    func testSignatureBlockStopsAtTheCommitMessage() {
        let raw = """
        tree b9937ca82b21d8b4a6c7ac37ac770b869213955e
        parent 9f65b0173a5e8e3fc405ea2ebc4c14dd7d803153
        author tugane hup <t@h.rw> 1789037462 +0200
        committer tugane hup <t@h.rw> 1789037462 +0200
        gpgsig -----BEGIN SSH SIGNATURE-----
         U1NIU0lHAAAAAQ
         AAAH8AAAAi
         -----END SSH SIGNATURE-----

        fix(products): stop the add-product flow failing
         an indented line in the message must not be swallowed
        """
        XCTAssertEqual(DoctorService.signatureBlock(inRawCommit: raw),
                       "-----BEGIN SSH SIGNATURE-----\nU1NIU0lHAAAAAQ\nAAAH8AAAAi\n-----END SSH SIGNATURE-----")
        XCTAssertNil(DoctorService.signatureBlock(inRawCommit: "tree abc\n\nunsigned commit"))
    }

    // MARK: findings

    private func org() -> Organization {
        Organization(name: "hup", displayName: "Hup", gitAuthorName: "A", gitEmail: "a@x",
                     forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: "/tmp/vk-hup",
                     keyLabel: "ssh-hup", signingEnabled: true, vault: .mounted)
    }

    private func findings(log: String, signature: String) async -> [DoctorFinding] {
        let runner = FakeRunner()
        runner.responses = [
            ("log", CommandResult(status: 0, stdout: log, stderr: "")),
            ("cat-file", CommandResult(status: 0, stdout: "tree abc\ngpgsig " +
                signature.split(separator: "\n").joined(separator: "\n ") + "\n\nsubject", stderr: "")),
        ]
        return await DoctorService(runner: runner).signatureFindings(repo: "hup-api", path: "/tmp/vk-hup/hup-api", org: org())
    }

    /// The bug this check shipped with: it scanned twenty commits and then told
    /// the user to amend the tip, which in the repository that surfaced it was
    /// a different, correctly signed commit. Nothing may point at the tip, and
    /// the flag letter must not leak into the prose.
    func testNamesTheFailingCommitAndNotTheTip() async {
        let log = """
        a4caedf0000000000000000000000000000000 G
        54f169e0000000000000000000000000000000 B
        9f65b010000000000000000000000000000000 N
        """
        let found = await findings(log: log, signature: signedNothing)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].detail.contains("54f169e"), "must name the commit that actually failed")
        XCTAssertFalse(found[0].detail.contains("a4caedf"), "the tip verifies and is none of this finding's business")
        XCTAssertFalse(found[0].detail.contains("54f169e B"), "the %G? flag must not leak into the detail line")
    }

    func testEmptySignatureAndMismatchAreGradedApart() async {
        let one = "54f169e0000000000000000000000000000000 B"
        let glitch = await findings(log: one, signature: signedNothing)
        XCTAssertEqual(glitch.first?.severity, .warning)

        let tamper = await findings(log: one, signature: complete)
        XCTAssertEqual(tamper.first?.severity, .critical,
                       "a signature over different content is the case worth waking someone for")
    }

    func testUncheckableSignaturesAreTheirOwnFinding() async {
        let found = await findings(log: "54f169e0000000000000000000000000000000 E", signature: complete)
        XCTAssertEqual(found.first?.checkName, "Commit signatures git cannot check")
        XCTAssertEqual(found.first?.severity, .warning)
    }

    func testCleanHistoryIsSilent() async {
        let found = await findings(log: "a4caedf0000000000000000000000000000000 G\n9f65b010000000000000000000000000000000 N",
                                   signature: complete)
        XCTAssertTrue(found.isEmpty)
    }

    /// Vaultkit's Scanner treats commit rewriting as a compromise indicator
    /// (the PolinRider propagation rule). The Doctor must not hand the user the
    /// same technique as routine advice, and re-signing would in any case
    /// destroy the evidence these findings exist to preserve.
    func testNoFindingTellsTheUserToRewriteHistory() async {
        var all: [DoctorFinding] = []
        for signature in [signedNothing, complete] {
            all += await findings(log: "54f169e0000000000000000000000000000000 B\n0000000111111111111111111111111111111 E",
                                  signature: signature)
        }
        XCTAssertFalse(all.isEmpty)
        for finding in all {
            let text = finding.detail + " " + (finding.remediation ?? "")
            for banned in ["--amend", "rebase", "push --force", "force-push", "filter-branch"] {
                XCTAssertFalse(text.contains(banned),
                               "\(finding.checkName) offers a history rewrite: \(banned)")
            }
            XCTAssertFalse(finding.autoFixable, "\(finding.checkName) must not be automated")
        }
    }
}
