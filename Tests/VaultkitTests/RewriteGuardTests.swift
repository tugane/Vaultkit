import XCTest
@testable import Vaultkit

/// The hook is a shell script built by string interpolation, so the only test
/// worth much is the one that hands it to a real git and watches what happens.
/// These drive actual repositories in a temporary directory.
final class RewriteGuardTests: XCTestCase {
    private var root: URL!
    private var guardian: RewriteGuard!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vaultkit-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guardian = RewriteGuard(journal: root.appendingPathComponent("attempts.log"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: driving git

    @discardableResult
    private func git(_ arguments: [String], in repo: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@x",
            "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@x",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            // Fixed timestamps make every commit object deterministic, which is
            // what lets testAnAmendThatChangesNothingIsNotARewrite produce a
            // genuinely byte-identical amend instead of depending on whether
            // the clock ticked over mid-test.
            "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
        ]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func org(at path: String) -> Organization {
        Organization(name: "t", displayName: "T", gitAuthorName: "T", gitEmail: "t@x",
                     forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: path,
                     keyLabel: "ssh-t", signingEnabled: true, vault: .mounted)
    }

    /// A vault holding one repository with two commits, hook installed.
    private func vaultWithRepo(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let repo = root.appendingPathComponent("vault/project")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "."], in: repo)
        for name in ["a", "b"] {
            try "\(name)\n".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
            try git(["add", "."], in: repo)
            try git(["commit", "-qm", name], in: repo)
        }
        let report = guardian.install(in: [org(at: root.appendingPathComponent("vault").path)])
        XCTAssertEqual(report.protected, ["project"], file: file, line: line)
        return repo
    }

    private func head(_ repo: URL) throws -> String {
        try git(["rev-parse", "HEAD"], in: repo).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: what it refuses

    func testRefusesAnAmendThatReplacesACommit() throws {
        let repo = try vaultWithRepo()
        let before = try head(repo)

        let amend = try git(["commit", "--amend", "-m", "reworded"], in: repo)
        XCTAssertNotEqual(amend.status, 0, "the amend must fail")
        XCTAssertTrue(amend.output.contains("Vaultkit"), "the refusal must say who refused: \(amend.output)")
        XCTAssertEqual(try head(repo), before, "history must be untouched")
    }

    /// The reason this is a reference-transaction hook and not a pre-commit
    /// one: --no-verify skips those, and anything rewriting history on purpose
    /// will pass it.
    func testNoVerifyDoesNotGetPastIt() throws {
        let repo = try vaultWithRepo()
        let before = try head(repo)
        let amend = try git(["commit", "--amend", "-m", "sneaky", "--no-verify"], in: repo)
        XCTAssertNotEqual(amend.status, 0)
        XCTAssertEqual(try head(repo), before)
    }

    /// The shape PolinRider used: a payload added to a commit that already has
    /// somebody's name and yesterday's date on it.
    func testRefusesAPayloadAmendedIntoAnExistingCommit() throws {
        let repo = try vaultWithRepo()
        let before = try head(repo)
        try "loader\n".write(to: repo.appendingPathComponent("loader.js"), atomically: true, encoding: .utf8)
        try git(["add", "loader.js"], in: repo)
        XCTAssertNotEqual(try git(["commit", "--amend", "--no-edit"], in: repo).status, 0)
        XCTAssertEqual(try head(repo), before)
    }

    func testRefusesRebaseAndBackwardReset() throws {
        let repo = try vaultWithRepo()
        let before = try head(repo)
        XCTAssertNotEqual(try git(["reset", "--hard", "HEAD~1"], in: repo).status, 0)
        XCTAssertEqual(try head(repo), before, "a backward reset drops a commit and must be refused")
    }

    // MARK: what it must not break

    func testOrdinaryWorkIsUntouched() throws {
        let repo = try vaultWithRepo()
        let before = try head(repo)

        try "c\n".write(to: repo.appendingPathComponent("c"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        XCTAssertEqual(try git(["commit", "-qm", "third"], in: repo).status, 0, "a new commit is not a rewrite")
        XCTAssertNotEqual(try head(repo), before)

        XCTAssertEqual(try git(["branch", "feature"], in: repo).status, 0, "creating a branch is not a rewrite")
        XCTAssertEqual(try git(["branch", "-D", "feature"], in: repo).status, 0, "deleting one is not either")
        XCTAssertEqual(try git(["checkout", "-qb", "topic"], in: repo).status, 0)
    }

    /// An amend that produces a byte-identical commit updates the ref to the
    /// hash it already holds. Nothing is replaced, and refusing it would be
    /// noise. Deterministic only because the git helper pins the timestamps.
    func testAnAmendThatChangesNothingIsNotARewrite() throws {
        let repo = try vaultWithRepo()
        let before = try head(repo)
        let amend = try git(["commit", "--amend", "--no-edit"], in: repo)
        XCTAssertEqual(try head(repo), before, "the amend must have been a no-op for this test to mean anything")
        XCTAssertEqual(amend.status, 0, "a ref update to the hash it already holds is not a rewrite")
    }

    // MARK: installing

    func testAnotherToolsHookIsReportedAndNeverTouched() throws {
        let repo = try vaultWithRepo()
        let hook = repo.appendingPathComponent(".git/hooks/reference-transaction")
        let theirs = "#!/bin/sh\n# somebody else's\nexit 0\n"
        try theirs.write(to: hook, atomically: true, encoding: .utf8)

        let vault = org(at: root.appendingPathComponent("vault").path)
        let report = guardian.install(in: [vault])
        XCTAssertEqual(report.conflicted, ["project"])
        XCTAssertTrue(report.protected.isEmpty)
        XCTAssertEqual(try String(contentsOf: hook, encoding: .utf8), theirs, "their file must survive")

        guardian.uninstall(from: [vault])
        XCTAssertEqual(try String(contentsOf: hook, encoding: .utf8), theirs, "uninstall must not delete it either")
    }

    func testInstallIsIdempotentAndUninstallIsClean() throws {
        let repo = try vaultWithRepo()
        let vault = org(at: root.appendingPathComponent("vault").path)
        XCTAssertEqual(guardian.install(in: [vault]).protected, ["project"], "installing twice is fine")

        guardian.uninstall(from: [vault])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/hooks/reference-transaction").path))
        XCTAssertEqual(try git(["commit", "--amend", "-m", "now allowed"], in: repo).status, 0,
                       "with the guard off, an amend is ordinary work again")
    }

    // MARK: the journal

    func testEveryRefusalIsRecordedBeforeItIsRefused() throws {
        let repo = try vaultWithRepo()
        XCTAssertTrue(guardian.attempts().isEmpty)

        try git(["commit", "--amend", "-m", "one"], in: repo)
        try git(["commit", "--amend", "-m", "two"], in: repo)

        let attempts = guardian.attempts()
        XCTAssertEqual(attempts.count, 2, "both attempts are on the record even though neither landed")
        XCTAssertEqual(attempts.first?.repo, "project")
        XCTAssertEqual(attempts.first?.branch, try git(["branch", "--show-current"], in: repo)
            .output.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertGreaterThan(attempts.first!.at, Date(timeIntervalSinceNow: -60))

        guardian.forgetAttempts()
        XCTAssertTrue(guardian.attempts().isEmpty)
    }
}

/// Exemptions are per organization by name, and turning one off has to take the
/// hook back out — a hook left behind would keep refusing rewrites with nothing
/// in the UI to explain why.
extension RewriteGuardTests {
    func testAnExemptOrganizationHasItsHookRemoved() throws {
        let repo = try vaultWithRepo()
        let vault = org(at: root.appendingPathComponent("vault").path)
        let hook = repo.appendingPathComponent(".git/hooks/reference-transaction")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hook.path))

        // What AppStore.applyRewriteGuard does once the org is exempt.
        guardian.uninstall(from: [vault])
        XCTAssertFalse(FileManager.default.fileExists(atPath: hook.path))
        XCTAssertEqual(try git(["commit", "--amend", "-m", "allowed here"], in: repo).status, 0)
    }

    func testExemptionsRoundTripByName() {
        let suite = "vaultkit-exempt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        XCTAssertTrue(RewriteGuard.exempt(in: defaults).isEmpty)
        RewriteGuard.setExempt(["me", "hup"], in: defaults)
        XCTAssertEqual(RewriteGuard.exempt(in: defaults), ["hup", "me"])
    }
}
