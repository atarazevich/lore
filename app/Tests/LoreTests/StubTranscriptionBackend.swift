import Foundation
@testable import LoreKit

enum StubBackendError: Error { case prepareFailed }

/// Shared test double for `TranscriptionBackend` — used by the protocol-contract
/// tests and the SharedBackendCache dedup tests. `yieldDuringPrepare` lets a
/// racing caller enter `prepare()` before the first one finishes; `failOnPrepare`
/// exercises the error paths.
final class StubTranscriptionBackend: TranscriptionBackend, @unchecked Sendable {
    private let statusMessage: String
    private let failOnPrepare: Bool
    private let yieldDuringPrepare: Bool
    private var prepared = false

    init(
        statusMessage: String = "Preparing Mock...",
        failOnPrepare: Bool = false,
        yieldDuringPrepare: Bool = false
    ) {
        self.statusMessage = statusMessage
        self.failOnPrepare = failOnPrepare
        self.yieldDuringPrepare = yieldDuringPrepare
    }

    func checkStatus() -> BackendStatus { .ready }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        onStatus(statusMessage)
        if yieldDuringPrepare { await Task.yield() }
        if failOnPrepare { throw StubBackendError.prepareFailed }
        prepared = true
    }

    func transcribe(_ samples: [Float], previousContext: String? = nil) async throws -> String {
        guard prepared else { throw TranscriptionBackendError.notPrepared }
        return "mock transcription"
    }
}
