import XCTest
@testable import Vaultkit

/// A scripted stand-in for the system. Every diskutil invocation is recorded so
/// tests can assert on what the service actually asked the system to do.
final class FakeRunner: SystemCommandRunning, @unchecked Sendable {
    var responses: [(match: String, result: CommandResult)] = []
    private(set) var calls: [[String]] = []
    var fallback = CommandResult(status: 0, stdout: "", stderr: "")

    func run(_ tool: String, _ arguments: [String], stdin: String?, cwd: String?) async throws -> CommandResult {
        calls.append(arguments)
        let joined = arguments.joined(separator: " ")
        for r in responses where joined.contains(r.match) { return r.result }
        return fallback
    }

    var didAttemptLock: Bool { calls.contains { $0.joined(separator: " ").contains("lockVolume") } }

    /// A `diskutil apfs list -plist` payload with one volume in a given state.
    static func plist(name: String, locked: Bool, mountPoint: String?) -> CommandResult {
        let mp = mountPoint.map { "<key>MountPoint</key><string>\($0)</string>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Containers</key><array><dict>
        <key>ContainerReference</key><string>disk3</string>
        <key>Volumes</key><array><dict>
        <key>DeviceIdentifier</key><string>disk3s7</string>
        <key>Name</key><string>\(name)</string>
        <key>Locked</key><\(locked ? "true" : "false")/>
        <key>FileVault</key><true/>
        \(mp)
        </dict></array></dict></array></dict></plist>
        """
        return CommandResult(status: 0, stdout: xml, stderr: "")
    }
}

private func org(_ name: String, folder: String) -> Organization {
    Organization(name: name, displayName: name.capitalized,
                 gitAuthorName: "T", gitEmail: "t@example.com",
                 forge: .custom, forgeHost: "", forgeSSHPort: nil,
                 folderPath: folder, keyLabel: "ssh-\(name)",
                 signingEnabled: true, vault: .none)
}

final class VaultStateTests: XCTestCase {

    /// The bug that started it all: a volume can be unmounted yet still hold its
    /// keys (a Time Machine snapshot does this). That is NOT at rest.
    func testUnmountedButUnlockedIsNotReportedAsAtRest() async throws {
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Me", locked: false, mountPoint: nil))]
        let service = DiskUtilVaultService(runner: runner, mountTable: { [:] })

        let state = try await service.state(of: org("me", folder: "~/work/me"))
        XCTAssertEqual(state, .unlocked, "cached keys must never be shown as locked/at-rest")
    }

    func testLockedVolumeIsAtRest() async throws {
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Me", locked: true, mountPoint: nil))]
        let service = DiskUtilVaultService(runner: runner, mountTable: { [:] })

        let state = try await service.state(of: org("me", folder: "~/work/me"))
        XCTAssertEqual(state, .locked)
    }

    /// Mounted somewhere other than the org folder means the org's git identity,
    /// direnv and registry config never activate: a distinct state, not "mounted".
    func testMountedAtWrongPathIsMisplaced() async throws {
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Me", locked: false, mountPoint: "/Volumes/Me"))]
        let service = DiskUtilVaultService(runner: runner, mountTable: { [:] })

        let state = try await service.state(of: org("me", folder: "~/work/me"))
        XCTAssertEqual(state, .misplaced)
    }

    func testMountedAtCanonicalPathIsMounted() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Me", locked: false,
                                                           mountPoint: "\(home)/work/me"))]
        let service = DiskUtilVaultService(runner: runner, mountTable: { [:] })

        let state = try await service.state(of: org("me", folder: "~/work/me"))
        XCTAssertEqual(state, .mounted)
    }

    /// diskutil's plist omits MountPoint for anything mounted outside /Volumes,
    /// which is every vault. The kernel's mount table is the tie-breaker: and
    /// it must never turn a plain unmounted volume into a mounted one.
    func testKernelMountTableFillsInWhatDiskutilOmits() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Me", locked: false, mountPoint: nil))]

        let canonical = DiskUtilVaultService(runner: runner, mountTable: { ["/dev/disk3s7": "\(home)/work/me"] })
        let s1 = try await canonical.state(of: org("me", folder: "~/work/me"))
        XCTAssertEqual(s1, .mounted)

        let elsewhere = DiskUtilVaultService(runner: runner, mountTable: { ["/dev/disk3s7": "/Volumes/Me"] })
        let s2 = try await elsewhere.state(of: org("me", folder: "~/work/me"))
        XCTAssertEqual(s2, .misplaced)

        // A snapshot mount of the same device must not count as the volume.
        let snapshot = DiskUtilVaultService(runner: runner, mountTable: { ["com.apple.TimeMachine.2026@/dev/disk3s7": "/Volumes/.timemachine/x"] })
        let s3 = try await snapshot.state(of: org("me", folder: "~/work/me"))
        XCTAssertEqual(s3, .unlocked)
    }

    func testMissingVolumeMeansNoVault() async throws {
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Somebody", locked: true, mountPoint: nil))]
        let service = DiskUtilVaultService(runner: runner, mountTable: { [:] })

        let state = try await service.state(of: org("me", folder: "~/work/me"))
        XCTAssertEqual(state, VaultState.none)
    }

    /// Ejecting an unmounted-but-unlocked volume must still drop the keys,
    /// otherwise "ejected" is a lie the UI repeats.
    func testEjectLocksAnUnmountedButUnlockedVolume() async throws {
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Me", locked: false, mountPoint: nil))]
        let service = DiskUtilVaultService(runner: runner, mountTable: { [:] })

        // The post-lock verification can't succeed against a static fake, so the
        // call is expected to throw. What matters is that it TRIED to lock.
        _ = try? await service.eject(org("me", folder: "~/work/me"))
        XCTAssertTrue(runner.didAttemptLock, "eject must lock a key-cached volume")
    }

    /// Bulk lookup exists so a refresh costs one subprocess, not one per org.
    func testStatesForManyOrgsIssuesASingleDiskutilCall() async throws {
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Me", locked: true, mountPoint: nil))]
        let service = DiskUtilVaultService(runner: runner, mountTable: { [:] })

        _ = await service.states(for: [org("me", folder: "~/work/me"),
                                       org("globex", folder: "~/work/globex"),
                                       org("initech", folder: "~/work/initech")])
        let listCalls = runner.calls.filter { $0.joined(separator: " ").contains("apfs list") }
        XCTAssertEqual(listCalls.count, 1)
    }
}

/// The guard's whole job is to make the *placeholder* unwritable. Applied over a
/// live mount it rewrites the volume ROOT's mode, which is stored inside the
/// volume, so every later mount comes back unreadable. diskutil can report a
/// successful lock while the volume is still mounted, which is how this fired.
final class GuardSafetyTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "vaultkit-guard-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
        try? FileManager.default.removeItem(atPath: root)
    }

    /// A plain directory is a legitimate guard target: closing it must work.
    func testGuardClosesOverAPlainPlaceholder() async throws {
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Guard", locked: true, mountPoint: nil))]
        let service = DiskUtilVaultService(runner: runner, mountTable: { [:] })

        _ = try? await service.eject(org("guard", folder: root))
        let mode = try FileManager.default.attributesOfItem(atPath: root)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o000, "a bare placeholder should be closed")
    }

    /// The regression, tested at the decision the fix turns on: the guard asks
    /// "is this path a live mount point?" before touching permissions. With the
    /// old path-blind guard this distinction did not exist, and closing over a
    /// mounted vault rewrote its root mode permanently.
    func testMountPointsAreDistinguishedFromPlaceholders() {
        let service = DiskUtilVaultService(runner: FakeRunner(), mountTable: { [:] })

        XCTAssertTrue(service.isMountPoint("/"), "the root filesystem is a mount point")
        XCTAssertFalse(service.isMountPoint(root),
                       "a plain directory is a placeholder and may be guarded")
        XCTAssertFalse(service.isMountPoint(root + "/does-not-exist"),
                       "a missing path is not a mount point")
    }

    /// A vault mounted at its canonical path must survive an eject attempt that
    /// fails to actually unmount it: permissions untouched, not zeroed.
    func testGuardLeavesAMountedVaultReadable() async throws {
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Live", locked: false, mountPoint: "/"))]
        let service = DiskUtilVaultService(runner: runner, mountTable: { [:] })

        _ = try? await service.eject(org("live", folder: "/"))
        let mode = try FileManager.default.attributesOfItem(atPath: "/")[.posixPermissions] as? NSNumber
        XCTAssertNotEqual(mode?.intValue, 0o000)
    }
}

final class GitURLTests: XCTestCase {

    func testHostParsingCoversBothSSHForms() {
        XCTAssertEqual(GitService.host(of: "git@github.com:tugane/vaultkit.git"), "github.com")
        XCTAssertEqual(GitService.host(of: "ssh://git@forge.example.rw:2222/org/repo.git"), "forge.example.rw")
        XCTAssertNil(GitService.host(of: "https://github.com/tugane/vaultkit.git"))
        XCTAssertNil(GitService.host(of: "not a url"))
    }
}
