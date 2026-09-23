import XCTest
@testable import Vaultkit

/// The decision half of auto-secure, which is the half worth testing: whether a
/// Mac actually sleeps cannot be faked, but "given this policy, this trigger and
/// this idle time, which vaults close" can be pinned exactly.
final class AutoSecureTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "vaultkit-autosecure-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { UserDefaults.standard.removePersistentDomain(forName: suite) }

    private func org(_ name: String, _ state: VaultState = .mounted) -> Organization {
        Organization(name: name, displayName: name.capitalized, gitAuthorName: "A", gitEmail: "a@x",
                     forge: .custom, forgeHost: "", forgeSSHPort: nil, folderPath: "~/work/\(name)",
                     keyLabel: "ssh-\(name)", signingEnabled: true, vault: state)
    }

    private var exposed: [Organization] { [org("hup"), org("rmsoft"), org("me")] }
    private var policy: AutoSecurePolicy { .standard }

    private func names(_ orgs: [Organization]) -> [String] { orgs.map(\.name) }

    // MARK: idle

    func testIdleWaitsForTheThreshold() {
        let hour: TimeInterval = 60 * 60
        XCTAssertTrue(policy.targets(for: .idle, idleSeconds: hour - 1, exposed: exposed, busy: []).isEmpty,
                      "one second short of the threshold is still someone at their desk")
        XCTAssertEqual(names(policy.targets(for: .idle, idleSeconds: hour, exposed: exposed, busy: [])),
                       ["hup", "rmsoft", "me"])
    }

    /// The other three triggers are events, not durations: idle time is
    /// irrelevant to them. Locking the screen two seconds after typing still
    /// means you walked away.
    func testEventTriggersIgnoreIdleTime() {
        for trigger in [SecureTrigger.screenLock, .sleep, .quit] {
            XCTAssertEqual(policy.targets(for: trigger, idleSeconds: 0, exposed: exposed, busy: []).count, 3,
                           "\(trigger) should not wait for an idle threshold")
        }
    }

    func testIdleIsDisabledByAZeroInterval() {
        var p = policy
        p.idleMinutes = 0
        XCTAssertFalse(p.allows(.idle))
        XCTAssertTrue(p.targets(for: .idle, idleSeconds: 86_400, exposed: exposed, busy: []).isEmpty)
    }

    // MARK: switches

    func testDisablingThePolicyStopsEveryTrigger() {
        var p = policy
        p.enabled = false
        for trigger in SecureTrigger.allCases {
            XCTAssertTrue(p.targets(for: trigger, idleSeconds: 86_400, exposed: exposed, busy: []).isEmpty,
                          "\(trigger) fired with auto-secure switched off")
        }
    }

    func testEachTriggerCanBeTurnedOffOnItsOwn() {
        var p = policy
        p.onSleep = false
        XCTAssertTrue(p.targets(for: .sleep, idleSeconds: 0, exposed: exposed, busy: []).isEmpty)
        XCTAssertFalse(p.targets(for: .screenLock, idleSeconds: 0, exposed: exposed, busy: []).isEmpty,
                       "turning off one trigger must not turn off the others")
    }

    // MARK: exclusions

    func testExemptOrganizationsAreLeftMounted() {
        var p = policy
        p.exempt = ["hup"]
        XCTAssertEqual(names(p.targets(for: .idle, idleSeconds: 86_400, exposed: exposed, busy: [])),
                       ["rmsoft", "me"])
    }

    /// A vault the app is already mounting or ejecting is the user at the
    /// keyboard. Racing them is worse than waiting for the next tick.
    func testVaultsWithAnActionInFlightAreSkipped() {
        XCTAssertEqual(names(policy.targets(for: .idle, idleSeconds: 86_400, exposed: exposed, busy: ["rmsoft"])),
                       ["hup", "me"])
    }

    func testNothingExposedMeansNothingToDo() {
        XCTAssertTrue(policy.targets(for: .quit, idleSeconds: 0, exposed: [], busy: []).isEmpty)
    }

    // MARK: persistence

    func testDefaultsAreOnAtAnHour() {
        let loaded = AutoSecurePolicy.load(from: defaults)
        XCTAssertEqual(loaded, .standard)
        XCTAssertTrue(loaded.enabled, "auto-secure ships on")
        XCTAssertEqual(loaded.idleMinutes, 60)
    }

    func testPolicyRoundTrips() {
        var p = policy
        p.enabled = true
        p.idleMinutes = 15
        p.onSleep = false
        p.exempt = ["hup", "me"]
        p.save(to: defaults)
        XCTAssertEqual(AutoSecurePolicy.load(from: defaults), p)
    }

    /// `false` must survive a round trip: reading it back with `?? true`
    /// against a missing key is the classic way a switch turns itself on again.
    func testTurningItOffSticks() {
        var p = policy
        p.enabled = false
        p.onScreenLock = false
        p.onQuit = false
        p.save(to: defaults)

        let loaded = AutoSecurePolicy.load(from: defaults)
        XCTAssertFalse(loaded.enabled)
        XCTAssertFalse(loaded.onScreenLock)
        XCTAssertFalse(loaded.onQuit)
    }

    func testTheUserIsToldOnlyOnce() {
        XCTAssertTrue(AutoSecurePolicy.needsAnnouncing(in: defaults))
        AutoSecurePolicy.markAnnounced(in: defaults)
        XCTAssertFalse(AutoSecurePolicy.needsAnnouncing(in: defaults))
    }

    // MARK: idle clock

    /// Not a behavioural test — it asserts the CoreGraphics call returns
    /// something usable, since a sentinel that stopped importing would silently
    /// disable the idle trigger.
    func testTheIdleClockReadsAPlausibleNumber() {
        let seconds = SystemIdle.seconds()
        XCTAssertGreaterThanOrEqual(seconds, 0)
        XCTAssertLessThan(seconds, 60 * 60 * 24 * 7)
    }
}
