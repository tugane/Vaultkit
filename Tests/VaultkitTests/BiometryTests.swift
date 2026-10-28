import XCTest
@testable import Vaultkit

/// The preflight's two halves, both pinned here because neither can be
/// exercised for real on a Mac whose lid is open: the ioreg parse is pinned
/// against captured output, and the decision is a pure function of the two
/// readings.
final class BiometryTests: XCTestCase {

    // MARK: ioreg

    /// Captured from `ioreg -r -k AppleClamshellState -d 4` on an Apple
    /// Silicon laptop. Trimmed to the shape that matters.
    private func ioreg(_ state: String) -> String {
        """
        +-o AppleARMPE  <class AppleARMPE, id 0x100000110, registered>
          | {
          |   "IOPlatformUUID" = "00000000-0000-0000-0000-000000000000"
          |   "AppleClamshellState" = \(state)
          |   "IOInterruptSpecifiers" = (<00000000>)
          | }
        """
    }

    func testLidClosedIsRead() {
        XCTAssertTrue(BiometryProbe.clamshellIsClosed(in: ioreg("Yes")))
    }

    func testLidOpenIsRead() {
        XCTAssertFalse(BiometryProbe.clamshellIsClosed(in: ioreg("No")))
    }

    /// A Mac with no lid has no such key. Empty output must read as open, or
    /// every desktop blocks on a sensor question it should never be asked.
    func testNoClamshellKeyReadsAsOpen() {
        XCTAssertFalse(BiometryProbe.clamshellIsClosed(in: ""))
    }

    /// Only the clamshell line counts. Another property whose value is "Yes"
    /// in the same dump must not be mistaken for the lid.
    func testOtherYesPropertiesAreIgnored() {
        let dump = """
          |   "AppleClamshellState" = No
          |   "AppleClamshellCausesSleep" = Yes
        """
        XCTAssertFalse(BiometryProbe.clamshellIsClosed(in: dump))
    }

    // MARK: the decision

    func testOpenLidWithASensorIsReady() {
        let status = BiometryStatus(sensorUsable: true, sensorDetail: "", lidClosed: false)
        XCTAssertNil(status.obstacle)
    }

    func testClosedLidBlocksEvenWhenTheFrameworkSaysYes() {
        let status = BiometryStatus(sensorUsable: true, sensorDetail: "", lidClosed: true)
        XCTAssertEqual(status.obstacle, .lidClosed)
    }

    /// With the lid down and a sensor the framework still vouches for, the only
    /// candidate is an external Touch ID keyboard — which the lid check cannot
    /// see, so the user gets the override.
    func testClosedLidWithAReachableSensorIsOverridable() {
        let status = BiometryStatus(sensorUsable: true, sensorDetail: "", lidClosed: true)
        XCTAssertTrue(status.overridable)
    }

    func testNoSensorBeatsTheLid() {
        let status = BiometryStatus(sensorUsable: false, sensorDetail: "No finger enrolled.",
                                    lidClosed: true)
        XCTAssertEqual(status.obstacle, .noSensor("No finger enrolled."))
    }

    /// Nothing to continue to: offering an override here would promise a prompt
    /// that cannot appear.
    func testNoSensorIsNotOverridable() {
        let status = BiometryStatus(sensorUsable: false, sensorDetail: "Touch ID is locked.",
                                    lidClosed: false)
        XCTAssertFalse(status.overridable)
    }

    func testDesktopWithoutBiometryIsBlockedNotLidBlamed() {
        let status = BiometryStatus(sensorUsable: false, sensorDetail: "Biometry is not available.",
                                    lidClosed: false)
        XCTAssertEqual(status.obstacle, .noSensor("Biometry is not available."))
    }

    // MARK: what the user is told

    func testTheLidMessageSaysItResumesByItself() {
        XCTAssertTrue(BiometryObstacle.lidClosed.detail.contains("Open the lid"))
        XCTAssertEqual(BiometryObstacle.lidClosed.headline, "The lid is closed")
    }

    /// The framework's own sentence has to survive into the hint, otherwise
    /// "not enrolled" and "locked out" are indistinguishable to the user.
    func testTheSensorMessageCarriesTheFrameworksReason() {
        let hint = BiometryObstacle.noSensor("No finger is enrolled.").hint
        XCTAssertTrue(hint.contains("no finger is enrolled."), hint)
    }
}
