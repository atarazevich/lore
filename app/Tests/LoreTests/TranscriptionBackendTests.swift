import XCTest
@testable import LoreKit

final class TranscriptionBackendTests: XCTestCase {

    // MARK: - ParakeetBackend

    func testParakeetDisplayName() {
        let backend = ParakeetBackend()
        XCTAssertEqual(backend.displayName, "Parakeet TDT v3")
    }

    func testParakeetCheckStatusReturnsNeedsDownloadOrReady() {
        let backend = ParakeetBackend()
        let status = backend.checkStatus()
        switch status {
        case .ready, .needsDownload:
            break
        default:
            XCTFail("Expected .ready or .needsDownload, got \(status)")
        }
    }

    func testParakeetTranscribeWithoutPrepareThrows() async {
        let backend = ParakeetBackend()
        do {
            _ = try await backend.transcribe([0.0, 0.1, 0.2])
            XCTFail("Expected error")
        } catch is TranscriptionBackendError {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Mock Backend (protocol contract)

    func testMockBackendPrepareSetStatus() async throws {
        let mock = MockTranscriptionBackend()
        let collector = StatusCollector()
        try await mock.prepare { status in
            collector.append(status)
        }
        XCTAssertEqual(collector.statuses, ["Preparing Mock..."])
    }

    func testMockBackendTranscribeAfterPrepare() async throws {
        let mock = MockTranscriptionBackend()
        try await mock.prepare { _ in }
        let text = try await mock.transcribe([1.0, 2.0, 3.0])
        XCTAssertEqual(text, "mock transcription")
    }

    func testMockBackendTranscribeWithoutPrepareThrows() async {
        let mock = MockTranscriptionBackend()
        do {
            _ = try await mock.transcribe([1.0])
            XCTFail("Expected error")
        } catch is TranscriptionBackendError {
            // Expected: notPrepared
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMockBackendCheckStatus() {
        let mock = MockTranscriptionBackend()
        XCTAssertEqual(mock.checkStatus(), .ready)
    }

    // MARK: - BackendStatus

    func testBackendStatusEquality() {
        XCTAssertEqual(BackendStatus.ready, BackendStatus.ready)
        XCTAssertNotEqual(BackendStatus.ready, BackendStatus.needsDownload)
        XCTAssertEqual(BackendStatus.needsDownload, BackendStatus.needsDownload)
    }
}

// MARK: - Test Helpers

private final class StatusCollector: @unchecked Sendable {
    var statuses: [String] = []
    func append(_ status: String) { statuses.append(status) }
}

// MARK: - Mock Backend

private final class MockTranscriptionBackend: TranscriptionBackend, @unchecked Sendable {
    private var prepared = false

    func checkStatus() -> BackendStatus { .ready }

    func prepare(onStatus: @Sendable (String) -> Void, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        onStatus("Preparing Mock...")
        prepared = true
    }

    func transcribe(_ samples: [Float], previousContext: String? = nil) async throws -> String {
        guard prepared else { throw TranscriptionBackendError.notPrepared }
        return "mock transcription"
    }
}
