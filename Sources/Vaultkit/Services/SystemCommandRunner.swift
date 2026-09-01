import Foundation

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// The single place in Vaultkit that spawns subprocesses (see data-flow.md).
/// Absolute tool paths only — never resolves via PATH, so a malicious shim
/// earlier in the user's PATH can't intercept a privileged-ish operation.
final class ProcessRunner: SystemCommandRunning, @unchecked Sendable {

    /// `stdin` is written to the process and the buffer is not retained.
    /// Used exclusively for `-stdinpassphrase` (see the I1 note in data-flow.md).
    func run(_ tool: String, _ arguments: [String], stdin: String?) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments

                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                // Never inherit the app's stdin: a child that decides to prompt
                // interactively (diskutil does, on a TTY) would block forever.
                // No stdin argument → the child sees EOF and must fail fast.
                let inPipe: Pipe? = stdin != nil ? Pipe() : nil
                process.standardInput = inPipe ?? FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                if let inPipe, let stdin {
                    // Throwing write: if the process exited before consuming
                    // stdin, this fails as a Swift error instead of raising an
                    // uncatchable NSFileHandle exception.
                    try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }

                // Drain both pipes concurrently: reading them sequentially can
                // deadlock when the process fills the un-drained pipe's buffer.
                var errData = Data()
                let errDone = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errDone.signal()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                errDone.wait()
                process.waitUntilExit()

                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
