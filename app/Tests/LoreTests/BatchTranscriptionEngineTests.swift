import XCTest
@testable import LoreKit

/// #43: import failure/preemption surfacing — a failed status must survive
/// `cancel()` (recording-start preemption is the only canceller and is never
/// a user choice against the import), and out-of-run failures are markable.
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

    /// `cancel()` must not stomp a `.failed` status: the preempted-import
    /// catch lands as failed, and the session's banner + retry depend on it.
    func testCancelPreservesFailedStatus() async {
        let engine = BatchTranscriptionEngine()
        let repo = SessionRepository(rootDirectory: rootDir)

        // A session with no batch audio fails immediately, without touching
        // any model — puts the engine into .failed.
        await engine.process(
            sessionID: "session_missing",
            sessionRepository: repo,
            notesDirectory: rootDir
        )
        guard case .failed = await engine.status else {
            return XCTFail("Precondition: process over a missing session must fail")
        }

        await engine.cancel()

        if case .failed = await engine.status {
            // preserved — the failed banner survives
        } else {
            XCTFail("cancel() must preserve a failed status, got \(await engine.status)")
        }
        let importing = await engine.isImporting
        XCTAssertFalse(importing)
    }

    /// Retry of an import whose session audio copy is gone surfaces as a
    /// normal failure for that session (banner + retry), set from outside a run.
    func testMarkFailedSetsFailedStatusForSession() async {
        let engine = BatchTranscriptionEngine()
        await engine.markFailed("Original audio no longer available", sessionID: "session_x")
        let status = await engine.status
        XCTAssertEqual(status, .failed("Original audio no longer available", sessionID: "session_x"))
    }
}
