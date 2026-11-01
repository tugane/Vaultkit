import XCTest
@testable import Vaultkit

/// Exclusions decide what the Scanner stops watching, so the matching rule is
/// worth pinning precisely: too loose and an organization quietly loses cover.
final class ScanExclusionTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "vaultkit-exclude-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { UserDefaults.standard.removePersistentDomain(forName: suite) }

    // MARK: matching

    func testExcludesTheDirectoryAndEverythingUnderIt() {
        let patterns = ["vendor"]
        XCTAssertTrue(ScanExclusions.excludes("vendor", patterns))
        XCTAssertTrue(ScanExclusions.excludes("vendor/lib/a.js", patterns))
    }

    /// The reason this matches segments rather than characters: a prefix test
    /// alone would silently stop watching a sibling directory.
    func testASiblingWithTheSamePrefixIsStillWatched() {
        XCTAssertFalse(ScanExclusions.excludes("vendor-utils/a.js", ["vendor"]))
        XCTAssertFalse(ScanExclusions.excludes("vendors/a.js", ["vendor"]))
    }

    func testNestedPathsMatchOnlyAtTheirOwnDepth() {
        let patterns = ["hup-api/drizzle"]
        XCTAssertTrue(ScanExclusions.excludes("hup-api/drizzle/0072.sql", patterns))
        XCTAssertFalse(ScanExclusions.excludes("drizzle/0072.sql", patterns),
                       "a nested exclusion must not match the same name at the root")
        XCTAssertFalse(ScanExclusions.excludes("other-api/drizzle/0072.sql", patterns))
    }

    func testNothingExcludedMatchesNothing() {
        XCTAssertFalse(ScanExclusions.excludes("anything/at/all", []))
    }

    // MARK: normalising

    /// An empty pattern would match the vault root and turn the Scanner off
    /// without saying so.
    func testEmptyAndRootPatternsAreRejected() {
        for raw in ["", "   ", "/", "///", "."] {
            XCTAssertNil(ScanExclusions.normalize(raw), "\(raw.debugDescription) must not become a pattern")
        }
        XCTAssertFalse(ScanExclusions.excludes("src/a.js", ["", "/"].compactMap(ScanExclusions.normalize)))
    }

    func testSlashesAndSpacingAreTidiedAway() {
        XCTAssertEqual(ScanExclusions.normalize("  /vendor/  "), "vendor")
        XCTAssertEqual(ScanExclusions.normalize("hup-api/drizzle/"), "hup-api/drizzle")
    }

    // MARK: storage

    func testStoredPerOrganizationAndNormalisedOnTheWayIn() {
        ScanExclusions.save(["  /drizzle/ ", "", "vendor"], for: "hup", to: defaults)
        XCTAssertEqual(ScanExclusions.load(for: "hup", from: defaults), ["drizzle", "vendor"])
        XCTAssertEqual(ScanExclusions.load(for: "me", from: defaults), [],
                       "one organization's list must not leak into another's")
    }

    // MARK: the incremental gotcha

    /// The Scanner only re-reads files whose timestamps moved. Un-excluding a
    /// directory therefore leaves it unscanned until something in it changes,
    /// unless the org's baseline is dropped — which is what invalidate does.
    func testInvalidateForcesTheNextPassToBeFull() async {
        let scanner = ScannerService()
        let org = Organization(name: "hup", displayName: "Hup", gitAuthorName: "A", gitEmail: "a@x",
                               forge: .custom, forgeHost: "", forgeSSHPort: nil,
                               folderPath: NSTemporaryDirectory() + "vk-\(UUID().uuidString)",
                               keyLabel: "ssh-hup", signingEnabled: true, vault: .mounted)
        try? FileManager.default.createDirectory(atPath: org.folderPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: org.folderPath) }

        let first = await scanner.scan(orgs: [org]).0
        XCTAssertTrue(first.full, "the first pass has no baseline to diff against")

        let second = await scanner.scan(orgs: [org]).0
        XCTAssertFalse(second.full, "the second pass diffs against the first")

        await scanner.invalidate(org.name)
        let third = await scanner.scan(orgs: [org]).0
        XCTAssertTrue(third.full, "after invalidate the next pass must read everything again")
    }
}
