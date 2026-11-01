import XCTest
@testable import Vaultkit

/// An eject blocked by open files names the processes, and offers to close
/// them. Signalling is the part worth pinning down: the app must never stop
/// itself, and must never pretend it can stop someone else's process.
final class EjectHolderTests: XCTestCase {

    /// Real `lsof +c 0 -F pcLu` output: one field per line, tagged by its
    /// first character. The old column split truncated Docker's helper to
    /// "com.docke" and would have broken on any name containing a space.
    private let output = """
    p936
    cwatchman
    u501
    Ltoo
    p31802
    ccom.docker.backend
    u501
    Ltoo
    p31837
    cGoogle Chrome Helper
    u0
    Lroot
    """

    func testParsesFullNamesAndOwnership() {
        let holders = DiskUtilVaultService.parseHolders(output, currentUID: 501)
        XCTAssertEqual(holders.map(\.pid), [936, 31802, 31837])
        XCTAssertEqual(holders[1].command, "com.docker.backend", "no nine-character truncation")
        XCTAssertEqual(holders[2].command, "Google Chrome Helper", "a name with spaces survives")
        XCTAssertEqual(holders.map(\.isMine), [true, true, false])
        XCTAssertEqual(holders[0].label, "watchman (pid 936)")
    }

    func testTheSameProcessIsListedOnce() {
        let repeated = output + "\np936\ncwatchman\nu501\nLtoo"
        XCTAssertEqual(DiskUtilVaultService.parseHolders(repeated, currentUID: 501).count, 3)
    }

    func testNothingOpenParsesToNothing() {
        XCTAssertTrue(DiskUtilVaultService.parseHolders("", currentUID: 501).isEmpty)
    }

    /// Signalling our own pid would take the app down in the middle of an
    /// eject, and another user's process cannot be stopped from here at all.
    func testOnlyOurOwnProcessesAreSignalable() {
        let holders = [
            VaultHolder(pid: 936, command: "watchman", user: "too", isMine: true),
            VaultHolder(pid: 4242, command: "Vaultkit", user: "too", isMine: true),
            VaultHolder(pid: 1, command: "launchd", user: "root", isMine: true),
            VaultHolder(pid: 31837, command: "mds", user: "root", isMine: false),
        ]
        let signalable = DiskUtilVaultService.signalable(holders, selfPID: 4242)
        XCTAssertEqual(signalable.map(\.pid), [936], "not ourselves, not pid 1, not another user's")
    }

    // MARK: what the alert says

    private func block(_ holders: [VaultHolder], wereAsked: Bool = false) -> EjectBlock {
        EjectBlock(org: Organization(name: "me", displayName: "Me", gitAuthorName: "A", gitEmail: "a@x",
                                     forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: "~/work/me",
                                     keyLabel: "ssh-me", signingEnabled: true, vault: .mounted),
                   holders: holders, wereAsked: wereAsked)
    }
    private let mine = VaultHolder(pid: 936, command: "watchman", user: "too", isMine: true)
    private let theirs = VaultHolder(pid: 31837, command: "mds", user: "root", isMine: false)

    /// The real case on this machine: ten holders, mostly repeats of a few
    /// commands. Listing ten pids is a wall of text in an alert.
    func testRepeatsAreGroupedByCommand() {
        let holders = [58703, 58752, 59499].map { VaultHolder(pid: Int32($0), command: "zsh", user: "too", isMine: true) }
            + [58724, 58776].map { VaultHolder(pid: Int32($0), command: "claude", user: "too", isMine: true) }
            + [VaultHolder(pid: 60574, command: "sleep", user: "too", isMine: true)]
        let summary = block(holders).summary
        XCTAssertTrue(summary.contains("zsh (3 processes)"), summary)
        XCTAssertTrue(summary.contains("claude (2 processes)"), summary)
        XCTAssertTrue(summary.contains("sleep (pid 60574)"), "a lone process keeps its pid")
        XCTAssertFalse(summary.contains("58703"), "repeats do not list every pid")
    }

    func testALongListIsTrimmed() {
        let holders = (1...9).map { VaultHolder(pid: Int32($0 + 100), command: "cmd\($0)", user: "too", isMine: true) }
        XCTAssertTrue(block(holders).summary.contains("and 4 others"), block(holders).summary)
    }

    func testFirstAskWarnsAboutUnsavedWork() {
        let m = block([mine]).message
        XCTAssertTrue(m.contains("watchman (pid 936)"))
        XCTAssertTrue(m.contains("Unsaved work"), m)
    }

    /// Forcing is a separate decision, and the wording has to say what it costs.
    func testForcingSaysItDoesNotSave() {
        XCTAssertTrue(block([mine], wereAsked: true).message.contains("without saving"))
    }

    func testProcessesWeCannotCloseAreNamed() {
        XCTAssertTrue(block([mine, theirs]).message.contains("another user"))
    }

    /// Nothing signalable: the alert must not offer to close anything.
    func testNothingToCloseIsSaidPlainly() {
        let b = block([theirs])
        XCTAssertTrue(b.mine.isEmpty)
        XCTAssertTrue(b.message.contains("cannot close them"), b.message)
    }
}
