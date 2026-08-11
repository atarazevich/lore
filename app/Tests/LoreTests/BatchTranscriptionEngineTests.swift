import XCTest
@testable import LoreKit

/// #166: engine status is a transient projection the healer owns. Cancel
/// leaves the engine idle (a preempted job is re-queued by the healer's own
/// bookkeeping, never a stored engine claim), and a terminal status is
/// acknowledged back to idle once the healer settles the job.
final class BatchTranscriptionEngineTests: XCTestCase {

    private var rootDir: URL!

    override func setUp() async throws {
        rootDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LoreBatchEngineTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootDir)
        rootDir = nil
    }

    /// Engine parked in `.failed`: a session with no batch audio fails
    /// immediately, without touching any model.
    private func makeFailedEngine() async -> BatchTranscriptionEngine? {
        let engine = BatchTranscriptionEngine()
        let repo = SessionRepository(rootDirectory: rootDir)
        await engine.process(
            sessionID: "session_missing",
            sessionRepository: repo,
            notesDirectory: rootDir
        )
        guard case .failed = await engine.status else {
            XCTFail("Precondition: process over a missing session must fail")
            return nil
        }
        return engine
    }

    /// `cancel()` returns the engine to idle regardless of prior status.
    func testCancelReturnsEngineToIdle() async {
        guard let engine = await makeFailedEngine() else { return }

        await engine.cancel()

        let status = await engine.status
        XCTAssertEqual(status, .idle, "cancel() must leave the engine idle")
        let importing = await engine.isImporting
        XCTAssertFalse(importing)
    }

    /// The healer acknowledges a terminal status once it has read it — no
    /// stale claim outlives the job (no-false-positives: live, not latched).
    func testAcknowledgeCompletionResetsTerminalStatus() async {
        guard let engine = await makeFailedEngine() else { return }

        await engine.acknowledgeCompletion()
        let status = await engine.status
        XCTAssertEqual(status, .idle)
    }
}
