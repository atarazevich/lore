import Foundation
@testable import LoreKit

enum StubBackendError: Error { case prepareFailed }

/// Shared test double for `TranscriptionBackend` — used by the protocol-contract
/// tests and the SharedBackendCache dedup tests. `yieldDuringPrepare` lets a
/// racing caller enter `prepare()` before the first one finishes; `failOnPrepare`
/// exercises the error paths; `transcript` is what it hears, and an empty one
/// stops the dictation pipeline at its no-speech branch — before the paste,
/// which would otherwise type into whatever the developer has in front of them.
final class StubTranscriptionBackend: TranscriptionBackend, @unchecked Sendable {
    private let statusMessage: String
    private let failOnPrepare: Bool
    private let yieldDuringPrepare: Bool
    private let transcript: String
    private var prepared = false

    /// Runs inside `prepare()`, before it returns — the seam for acting while a
    /// load is in flight (stopping the engine mid-load, say). Assigned after the
    /// object exists, so the hook can reach something built around it.
    var duringPrepare: (@MainActor @Sendable () -> Void)?

    init(
        statusMessage: String = "Preparing Mock...",
        failOnPrepare: Bool = false,
        yieldDuringPrepare: Bool = false,
        transcript: String = "mock transcription"
    ) {
        self.statusMessage = statusMessage
        self.failOnPrepare = failOnPrepare
        self.yieldDuringPrepare = yieldDuringPrepare
        self.transcript = transcript
    }

    func checkStatus() -> BackendStatus { .ready }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        onStatus(statusMessage)
        if yieldDuringPrepare { await Task.yield() }
        if let duringPrepare { await duringPrepare() }
        if failOnPrepare { throw StubBackendError.prepareFailed }
        prepared = true
    }

    func transcribe(_ samples: [Float], previousContext: String? = nil) async throws -> String {
        guard prepared else { throw TranscriptionBackendError.notPrepared }
        return transcript
    }
}

/// Uppercases what it is given and remembers it, so a test can see exactly
/// which spans reached the model — and, just as often, that none did.
final class LoudCleanupClient: CleanupProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var seen: [String] { lock.withLock { texts } }

    func cleanup(rawText: String, prompt: String, apiKey: String) async throws -> String {
        // `withLock`, not lock/unlock: the bare calls are unavailable from an
        // async context.
        lock.withLock { texts.append(rawText) }
        return rawText.uppercased()
    }
}

/// How many backends a factory was asked for — the count every "did it load a
/// second copy of the model" test is really asking about.
final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    @discardableResult
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
