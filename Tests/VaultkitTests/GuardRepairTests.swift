import XCTest
@testable import Vaultkit

/// A guard drifts open whenever something other than this app puts a vault at
/// rest: a Finder eject, work-off, a reboot. The repair runs unattended every
/// ten seconds, so these pin down exactly when it may act. The costly mistake
/// is not leaving a guard open for a while; it is closing one at the wrong
/// moment, over a live volume or a mount in progress.
final class GuardRepairTests: XCTestCase {
    private var root: String!
    /// Ten minutes on, so the guard reads as having sat open rather than as a
    /// mount that opened it moments ago.
    private let later = Date().addingTimeInterval(600)

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "vaultkit-guard-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
        try? FileManager.default.removeItem(atPath: root)
    }
    private var mode: Int {
        ((try? FileManager.default.attributesOfItem(atPath: root))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testDriftedEmptyGuardIsClosed() {
        XCTAssertEqual(DiskUtilVaultService.recloseGuard(at: root, now: later), .closed)
        XCTAssertEqual(mode, 0)
    }

    /// work-on opens the guard and then waits on a typed passphrase. Closing it
    /// inside that window would fail the mount the person is in the middle of.
    func testRecentlyOpenedGuardIsLeftForTheMountInProgress() {
        XCTAssertEqual(DiskUtilVaultService.recloseGuard(at: root), .skippedRecent)
        XCTAssertEqual(mode, 0o700)
    }

    /// Closing over trapped plaintext would hide it from the rescue the
    /// "Files trapped" finding asks for. That finding owns this case.
    func testGuardOverTrappedFilesIsLeftOpen() throws {
        try "draft".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(DiskUtilVaultService.recloseGuard(at: root, now: later), .skippedOccupied)
        XCTAssertEqual(mode, 0o700)
    }

    /// Finder writes .DS_Store into anything it shows. Counting it as trapped
    /// would leave every guard Finder has looked at open forever.
    func testFinderMetadataDoesNotHoldAGuardOpen() throws {
        try Data().write(to: URL(fileURLWithPath: root + "/.DS_Store"))
        XCTAssertEqual(DiskUtilVaultService.recloseGuard(at: root, now: later), .closed)
        XCTAssertEqual(mode, 0)
    }

    func testClosedGuardIsLeftAlone() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root)
        XCTAssertEqual(DiskUtilVaultService.recloseGuard(at: root, now: later), .alreadyClosed)
    }

    func testMissingPlaceholderIsNotCreated() {
        XCTAssertEqual(DiskUtilVaultService.recloseGuard(at: root + "/gone", now: later), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/gone"))
    }

    /// The property that matters most. chmod follows the path, so closing over
    /// a live mount rewrites the volume root, whose mode is stored inside the
    /// volume. Not the grace period, not an explicit press, nothing skips this.
    /// "/" is always a mount point, and a test process could not chmod it even
    /// if the check were broken, so this is safe to aim at.
    func testLiveMountIsNeverTouched() {
        XCTAssertEqual(DiskUtilVaultService.recloseGuard(at: "/", now: later, grace: 0, requireEmpty: false),
                       .skippedMounted)
    }

    /// A Fix press is explicit: it skips the grace period and the emptiness test.
    func testExplicitFixClosesARecentOccupiedGuard() throws {
        try "draft".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(DiskUtilVaultService.recloseGuard(at: root, grace: 0, requireEmpty: false), .closed)
        XCTAssertEqual(mode, 0)
    }
}

final class DoctorGuardTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "vaultkit-doctor-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
        try? FileManager.default.removeItem(atPath: root)
    }
    private func lockedOrg() -> Organization {
        Organization(name: "acme", displayName: "Acme", gitAuthorName: "A", gitEmail: "a@x",
                     forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: root,
                     keyLabel: "ssh-acme", signingEnabled: true, vault: .locked)
    }

    /// A .DS_Store under a locked vault used to raise a critical "Files
    /// trapped" finding for a folder someone had merely looked at.
    func testFinderMetadataIsNotTrappedPlaintext() async throws {
        try Data().write(to: URL(fileURLWithPath: root + "/.DS_Store"))
        let findings = await DoctorService(runner: FakeRunner()).runAllChecks(orgs: [lockedOrg()])
        XCTAssertFalse(findings.contains { $0.checkName == "Files trapped under a locked vault" })
    }

    func testRealFilesAreStillTrapped() async throws {
        try "x".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        let findings = await DoctorService(runner: FakeRunner()).runAllChecks(orgs: [lockedOrg()])
        XCTAssertEqual(findings.first { $0.checkName == "Files trapped under a locked vault" }?.severity, .critical)
    }

    /// The Fix button now goes through the same filesystem checks as the
    /// automatic repair instead of trusting cached state, and still closes.
    func testManualFixClosesTheGuard() async throws {
        let org = lockedOrg()
        let finding = DoctorFinding(checkName: "Open guard on locked vault", severity: .warning,
                                    detail: "", remediation: nil, autoFixable: true, orgName: org.name)
        await DoctorService(runner: FakeRunner()).applyFix(for: finding, orgs: [org])
        let mode = (try FileManager.default.attributesOfItem(atPath: root)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0)
    }
}
