import XCTest
@testable import Vaultkit

/// Inclusion in Time Machine is only a risk when the destination is not
/// encrypted: it copies files, so a mounted vault is copied as plaintext. The
/// check used to warn on inclusion alone, on a machine whose backup disk has a
/// password. Fixtures are the real tmutil and diskutil formats.
final class BackupCheckTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    private let unplugged = """
    ====================================================
    Name          : TOo BackUp
    Kind          : Local
    ID            : 27E4BAE5-62FE-43B9-81C9-7B1F3689EF0C
    """
    private let plugged = """
    ====================================================
    Name          : TOo BackUp
    Kind          : Local
    Mount Point   : /Volumes/TOo BackUp
    ID            : 27E4BAE5-62FE-43B9-81C9-7B1F3689EF0C
    """

    override func setUp() {
        suite = "vaultkit-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { UserDefaults.standard.removePersistentDomain(forName: suite) }

    private func org(_ name: String) -> Organization {
        Organization(name: name, displayName: name.capitalized, gitAuthorName: "A", gitEmail: "a@x",
                     forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: "/tmp/vk-\(name)",
                     keyLabel: "ssh-\(name)", signingEnabled: true, vault: .mounted)
    }

    private func check(destinations: String, fileVault: String? = nil,
                       excluded: Bool = false, orgs: [String] = ["me", "rmsoft"]) async -> [DoctorFinding] {
        let runner = FakeRunner()
        runner.responses = [
            ("destinationinfo", CommandResult(status: 0, stdout: destinations, stderr: "")),
            ("isexcluded", CommandResult(status: 0, stdout: excluded ? "[Excluded] x" : "[Included] x", stderr: "")),
        ]
        if let fileVault {
            runner.responses.append(("info /Volumes/TOo BackUp", CommandResult(
                status: 0, stdout: "   Volume Name:               TOo BackUp\n   FileVault:                 \(fileVault)\n",
                stderr: "")))
        }
        return await DoctorService(runner: runner, defaults: defaults).backupChecks(orgs: orgs.map(org))
    }

    func testParsesTheRealFormat() {
        let d = DoctorService.parseDestinations(plugged)
        XCTAssertEqual(d, [.init(id: "27E4BAE5-62FE-43B9-81C9-7B1F3689EF0C", name: "TOo BackUp",
                                 mountPoint: "/Volumes/TOo BackUp")])
        XCTAssertNil(DoctorService.parseDestinations(unplugged).first?.mountPoint,
                     "no Mount Point line while the disk is unplugged")
        XCTAssertEqual(DoctorService.parseDestinations(unplugged + "\n" + plugged).count, 2)
    }

    /// The reported case: the backup disk has a password, so every copy of a
    /// mounted vault on it is ciphertext and there is nothing to warn about.
    func testEncryptedDiskRaisesNothing() async {
        let findings = await check(destinations: plugged, fileVault: "Yes")
        XCTAssertTrue(findings.isEmpty, "\(findings.map(\.checkName))")
    }

    /// A backup disk is usually unplugged; what was learned while it was
    /// connected carries over.
    func testEncryptionLearnedWhileConnectedIsRemembered() async {
        _ = await check(destinations: plugged, fileVault: "Yes")
        let later = await check(destinations: unplugged)
        XCTAssertTrue(later.isEmpty)
    }

    func testUnencryptedDiskWarnsPerIncludedVault() async {
        let findings = await check(destinations: plugged, fileVault: "No")
        XCTAssertEqual(findings.count, 2)
        XCTAssertTrue(findings.allSatisfy { $0.checkName == "Vault backed up in plaintext" && $0.severity == .warning })
        XCTAssertEqual(findings.first?.detail.contains("TOo BackUp"), true, "names the disk")
    }

    /// Never seen connected: one note about the disk, not a warning per vault.
    /// A backup can only be written while the disk is connected, which is when
    /// the check learns the truth, so this never hides a live plaintext copy.
    func testUnknownDiskIsOneNote() async {
        let findings = await check(destinations: unplugged)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.severity, .info)
        XCTAssertEqual(findings.first?.checkName, "Backup encryption not yet checked")
    }

    /// Turning encryption off on the same disk is noticed the next time it is seen.
    func testAChangeOfHeartIsRelearned() async {
        _ = await check(destinations: plugged, fileVault: "Yes")
        let findings = await check(destinations: plugged, fileVault: "No")
        XCTAssertEqual(findings.first?.checkName, "Vault backed up in plaintext")
    }

    func testExcludedVaultsNeedNoEncryption() async {
        let findings = await check(destinations: plugged, fileVault: "No", excluded: true)
        XCTAssertTrue(findings.isEmpty)
    }

    /// A disk diskutil cannot describe (a network share, say) is never
    /// recorded as either answer.
    func testNoAnswerIsNotAGuess() async {
        let findings = await check(destinations: plugged)   // no diskutil response at all
        XCTAssertEqual(findings.first?.severity, .info)
        XCTAssertNil(defaults.object(forKey: "vk.backupEncrypted.27E4BAE5-62FE-43B9-81C9-7B1F3689EF0C"))
    }
}
