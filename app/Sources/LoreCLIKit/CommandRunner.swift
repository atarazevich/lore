import Foundation

/// What one run of an external command produced (#258).
///
/// Both streams are kept. A herdr call that refuses exits non-zero and writes
/// its own `{"error":{…}}` to standard error with nothing on standard output
/// (measured 2026-09-14), so a run that is only judged by its standard output
/// cannot tell a refusal from an answer. Neither stream is ever logged: a
/// command's text carries folders and titles.
public struct CommandOutput: Equatable, Sendable {
    public let status: Int32
    public let output: String
    public let errorOutput: String

    public init(status: Int32, output: String, errorOutput: String = "") {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
    }
}

/// Running another program is the one seam onto the machine outside lore
/// (#258): the herdr CLI, called by the app and by the `lore` command. A
/// protocol so every command line and every failure is unit-tested without
/// herdr, and so no test can reach the owner's panes.
public protocol CommandRunner: Sendable {
    /// Runs `executable` away from the main thread. Returns nil when it could
    /// not be started at all, or did not finish within `timeout` — a missing
    /// or wedged herdr must never hold the caller.
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async -> CommandOutput?
}

/// The live runner: `Process` on a background queue, killed at the timeout.
public struct SystemCommandRunner: CommandRunner {

    public init() {}

    /// What a child gets between the timeout's SIGTERM and SIGKILL. A child
    /// that ignores SIGTERM must still be reaped, or `waitUntilExit()` never
    /// returns and the promise above is not kept.
    public static let killGrace: TimeInterval = 0.5

    public func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async -> CommandOutput? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runBlocking(executable, arguments, timeout))
            }
        }
    }

    /// The same run, blocking the calling thread — what the `lore` command
    /// uses, having no async context of its own to wait in.
    public static func runBlocking(
        _ executable: URL, _ arguments: [String], _ timeout: TimeInterval
    ) -> CommandOutput? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let errors = Pipe()
        process.standardOutput = out
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return nil
        }
        // Each stream is read on its own thread: a child stops when a pipe
        // fills, and a grandchild can hold one open long after the child is
        // gone, so no read here decides when this returns.
        let stdout = StreamDrain(out.fileHandleForReading)
        let stderr = StreamDrain(errors.fileHandleForReading)
        let child = RunningChild(process)
        let watchdog = DispatchQueue.global(qos: .utility)
        let term = DispatchWorkItem { child.signal(SIGTERM) }
        let hardKill = DispatchWorkItem { child.signal(SIGKILL) }
        watchdog.asyncAfter(deadline: .now() + timeout, execute: term)
        watchdog.asyncAfter(deadline: .now() + timeout + killGrace, execute: hardKill)
        process.waitUntilExit()
        term.cancel()
        hardKill.cancel()
        child.finish()
        // Only a child that ran to its own end answered: a signal means the
        // watchdog killed it, or it died of something else.
        guard process.terminationReason == .exit else { return nil }
        // One deadline for both streams, not one each: whatever is still in a
        // pipe arrives at once, and the two waits are the same wait.
        let readBy = DispatchTime.now() + StreamDrain.grace
        return CommandOutput(
            status: process.terminationStatus,
            output: stdout.text(by: readBy),
            errorOutput: stderr.text(by: readBy)
        )
    }

    /// One stream, read to its end away from the caller.
    private final class StreamDrain: @unchecked Sendable {
        /// How long the text is waited for once the child is gone: what is
        /// still in the pipe arrives at once, and anything else holding the
        /// far end must not delay the answer.
        static let grace: TimeInterval = 1

        private let lock = NSLock()
        private var data = Data()
        private let read = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let all = handle.readDataToEndOfFile()
                lock.withLock { data = all }
                read.signal()
            }
        }

        func text(by deadline: DispatchTime) -> String {
            _ = read.wait(timeout: deadline)
            return lock.withLock { String(decoding: data, as: UTF8.self) }
        }
    }

    /// The child shared with its watchdog: whoever gets there first under the
    /// lock decides, so nothing is signalled once the run has been reaped.
    private final class RunningChild: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var reaped = false

        init(_ process: Process) { self.process = process }

        func signal(_ number: Int32) {
            lock.withLock {
                guard !reaped, process.isRunning else { return }
                kill(process.processIdentifier, number)
            }
        }

        func finish() { lock.withLock { reaped = true } }
    }
}
