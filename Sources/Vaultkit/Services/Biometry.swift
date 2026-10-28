import Foundation
import LocalAuthentication

/// Why the Touch ID prompt a step is about to raise cannot be answered.
enum BiometryObstacle: Equatable {
    /// Clamshell: the laptop is driving an external display with its lid shut,
    /// which takes the built-in sensor out of reach along with the keyboard.
    case lidClosed
    /// LocalAuthentication will not evaluate biometry at all: no sensor on this
    /// Mac, no finger enrolled, or biometry locked out after too many failures.
    case noSensor(String)

    var headline: String {
        switch self {
        case .lidClosed: "The lid is closed"
        case .noSensor: "Touch ID is not available"
        }
    }

    var detail: String {
        switch self {
        case .lidClosed:
            "The enclave key is biometry-gated and there is no passcode fallback, so this step needs a touch. Open the lid and it continues on its own."
        case .noSensor(let reason):
            "\(reason) The enclave key is biometry-gated and there is no passcode fallback, so this step cannot proceed until a sensor can answer."
        }
    }

    /// One line, for a sheet that wants to say this before the user starts
    /// rather than three steps in.
    var hint: String {
        switch self {
        case .lidClosed:
            "The lid is closed, so Touch ID cannot answer. Open it before you start, or this will wait until you do."
        case .noSensor(let reason):
            "Touch ID cannot answer: \(reason.prefix(1).lowercased() + reason.dropFirst())"
        }
    }

    var symbol: String {
        switch self {
        case .lidClosed: "laptopcomputer.slash"
        case .noSensor: "touchid"
        }
    }
}

/// What this Mac can do about a biometric prompt right now.
struct BiometryStatus: Equatable {
    /// `LAContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`.
    let sensorUsable: Bool
    /// LocalAuthentication's own words, when it said no.
    let sensorDetail: String
    /// IORegistry's `AppleClamshellState`. False on a Mac that has no lid.
    let lidClosed: Bool

    static let unknown = BiometryStatus(sensorUsable: true, sensorDetail: "", lidClosed: false)

    /// The decision, kept pure so the whole policy is testable on a Mac whose
    /// lid is open.
    ///
    /// A shut lid blocks even when LocalAuthentication reports the sensor
    /// usable. Clamshell disables the built-in sensor, so a usable sensor with
    /// the lid down means an external Touch ID keyboard — probably. The
    /// framework's answer in clamshell is not something Apple documents, and
    /// being wrong the other way means raising a prompt nobody can reach, so
    /// this warns and offers `overridable` rather than deciding for the user.
    var obstacle: BiometryObstacle? {
        if !sensorUsable { return .noSensor(sensorDetail) }
        if lidClosed { return .lidClosed }
        return nil
    }

    /// Whether "continue anyway" is honest: only when LocalAuthentication
    /// believes some sensor is reachable, which with the lid shut means an
    /// external one.
    var overridable: Bool { sensorUsable }
}

protocol BiometryProbing: Sendable {
    func status() async -> BiometryStatus
}

/// Reads the two independent signals: LocalAuthentication for whether biometry
/// can be evaluated, IORegistry for whether the lid is down. Neither alone is
/// the answer (see `BiometryStatus.obstacle`).
struct BiometryProbe: BiometryProbing {
    let runner: any SystemCommandRunning

    init(runner: any SystemCommandRunning = ProcessRunner()) { self.runner = runner }

    func status() async -> BiometryStatus {
        let (usable, detail) = Self.sensor()
        return BiometryStatus(sensorUsable: usable, sensorDetail: detail, lidClosed: await lidClosed())
    }

    /// A fresh `LAContext` every time. The class caches its evaluation, so a
    /// long-lived one would keep answering with the state at first ask, which
    /// is precisely the state we are sitting here waiting to see change.
    private static func sensor() -> (Bool, String) {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return (true, "")
        }
        let reason = error?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (false, reason.isEmpty ? "This Mac reports no usable Touch ID sensor." : reason)
    }

    /// `AppleClamshellState` is the lid as the kernel sees it. The key is absent
    /// entirely on a Mac that has no lid, which reads here as open: correct,
    /// since a desktop must never block on this.
    private func lidClosed() async -> Bool {
        guard let r = try? await runner.run("/usr/sbin/ioreg",
                                            ["-r", "-k", "AppleClamshellState", "-d", "4"]) else {
            return false
        }
        return Self.clamshellIsClosed(in: r.stdout)
    }

    /// Parsed apart from the call so the shape of ioreg's output is pinned by a
    /// test rather than by whatever the lid of the Mac running the suite is
    /// doing at the time.
    static func clamshellIsClosed(in ioregOutput: String) -> Bool {
        ioregOutput.split(separator: "\n")
            .filter { $0.contains("\"AppleClamshellState\"") }
            .contains { $0.contains("= Yes") }
    }
}

/// A step held back until the sensor can answer it. Lives on the store; the
/// sheet whose step is waiting renders it and owns the two ways out.
struct BiometryWait: Equatable {
    /// What is waiting, in the user's terms: "Creating the Acme key".
    let action: String
    let obstacle: BiometryObstacle
    let overridable: Bool
}
