import XCTest
@testable import Vaultkit

/// Acting on a hit must never lose bytes and must leave a working file behind.
final class QuarantineTests: XCTestCase {
    private var root: String!
    private let q = QuarantineService()

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "vaultkit-q-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/app/.git", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    private func write(_ rel: String, _ content: String) throws {
        let path = root + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }
    private func read(_ rel: String) throws -> String { try String(contentsOfFile: root + "/" + rel, encoding: .utf8) }
    private var org: Organization {
        Organization(name: "acme", displayName: "Acme", gitAuthorName: "A", gitEmail: "a@acme.test",
                     forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: root,
                     keyLabel: "ssh-acme", signingEnabled: true, vault: .mounted)
    }
    private func hits() async -> [ScanFinding] { await ScannerService().scan(orgs: [org]).1 }

    func testCleaningKeepsTheLegitimateConfigAndStashesTheOriginal() async throws {
        let legit = "export default {\n  plugins: { tailwindcss: {} },\n}"
        try write("app/postcss.config.mjs", legit + "\n\n\n\n\nglobal['!']='8-270-2';var _$_1e42=(\"rmcej%otb%\",2857687);eval(x)")
        let f = await hits().first { $0.fix == .clean }!
        let (action, item) = try q.remediate(f, vaultRoot: root)

        XCTAssertEqual(try read("app/postcss.config.mjs"), legit + "\n")
        XCTAssertEqual(action.kind, .cleaned)
        let held = try XCTUnwrap(item)
        XCTAssertEqual(held.kind, .cleaned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(root!)/.vaultkit/quarantine/\(held.id)/postcss.config.mjs.quarantined"))
        XCTAssertEqual(held.sha256.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(root!)/.vaultkit/quarantine/\(held.id)/record.json"))
    }

    func testAFileThatIsAllPayloadIsMovedWhole() async throws {
        try write("app/index.js", "global['r'] = require;global['m'] = module;(\"rmcej%otb%\",2857687)")
        let f = await hits().first!
        let (action, _) = try q.remediate(f, vaultRoot: root)
        XCTAssertEqual(action.kind, .quarantined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/app/index.js"))
    }

    func testArtifactsAreMovedNotDeleted() async throws {
        try write("app/temp_auto_push.bat", "@echo off\n")
        let f = await hits().first!
        let (_, item) = try q.remediate(f, vaultRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/app/temp_auto_push.bat"))
        let held = "\(root!)/.vaultkit/quarantine/\(try XCTUnwrap(item).id)/temp_auto_push.bat.quarantined"
        XCTAssertEqual(try String(contentsOfFile: held, encoding: .utf8), "@echo off\n")
    }

    func testDependencyRemovalLeavesValidJSONAndTheOtherDependencies() async throws {
        try write("app/package.json", """
        {
          "name": "client",
          "dependencies": {
            "react": "^18.0.0",
            "tailwindcss-style-animate": "^1.1.6"
          }
        }
        """)
        let f = await hits().first!
        _ = try q.remediate(f, vaultRoot: root)
        let after = try read("app/package.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: Any])
        let deps = try XCTUnwrap(json["dependencies"] as? [String: String])
        XCTAssertEqual(deps, ["react": "^18.0.0"])
        XCTAssertTrue(after.contains("  \"name\": \"client\","), "formatting of untouched lines is preserved")
    }

    func testRestorePutsTheOriginalBack() async throws {
        let infected = "export default {}\n\nglobal['!']='x';var _$_1e42=1"
        try write("app/tailwind.config.js", infected)
        let f = await hits().first!
        let (_, item) = try q.remediate(f, vaultRoot: root)
        XCTAssertEqual(try read("app/tailwind.config.js"), "export default {}\n")

        let action = try q.restore(try XCTUnwrap(item), vaultRoot: root)
        XCTAssertEqual(action.kind, .restored)
        XCTAssertEqual(try read("app/tailwind.config.js"), infected)
        XCTAssertTrue(q.items(in: root).isEmpty)
    }

    /// A quarantined payload must not be found again on the next pass.
    func testQuarantineIsNeverRescanned() async throws {
        try write("app/temp_auto_push.bat", "@echo off\n")
        let scanner = ScannerService()
        let (_, first) = await scanner.scan(orgs: [org])
        _ = try q.remediate(first[0], vaultRoot: root)
        let (_, again) = await scanner.scan(orgs: [org])
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(q.items(in: root).count, 1)
    }

    func testHistoryRoundTrips() throws {
        let url = URL(fileURLWithPath: root + "/history.json")
        let store = HistoryStore(url: url)
        var h = ScannerHistory()
        h.scans.append(ScanEvent(date: Date(), duration: 0.5, mode: "full", orgs: ["acme"], repos: 2, files: 9, hits: 1))
        h.actions.append(ActionEvent(date: Date(), kind: .cleaned, orgName: "acme", path: "app/x.mjs",
                                     indicator: "loader", detail: "cut", quarantineID: "id"))
        store.save(h)
        let back = store.load()
        XCTAssertEqual(back.scans.count, 1)
        XCTAssertEqual(back.actions.first?.kind, .cleaned)
        XCTAssertEqual(back.actions.first?.quarantineID, "id")
    }
}
