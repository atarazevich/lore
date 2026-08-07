import XCTest
@testable import LoreKit

/// #103: transient failures get a small retry budget — 3 attempts per failed
/// transcription chunk (immediate), 3 for cleanup/translate (transient errors
/// only, backoff). Final-failure fallbacks and messages are unchanged.
@MainActor
final class DictationRetryTests: XCTestCase {

    /// Distinct build numbers for the diagnostic fences below, so no two fences
    /// can collide — deterministically, so a rerun repeats exactly.
    private static var nextFenceBuild = 0

    /// Backend that replays a scripted result per `transcribe` call.
    private final class ScriptedBackend: TranscriptionBackend, @unchecked Sendable {
        private var results: [Result<String, any Error>]
        private(set) var calls = 0
        init(_ results: [Result<String, any Error>]) { self.results = results }
        func checkStatus() -> BackendStatus { .ready }
        func prepare(
            onStatus: @Sendable (String) -> Void,
            onProgress: @escaping @Sendable (Double) -> Void
        ) async throws {}
        func transcribe(_ samples: [Float], previousContext: String?) async throws -> String {
            calls += 1
            return try results.removeFirst().get()
        }
    }

    /// LLM client that replays a scripted result per `cleanup` call.
    private final class ScriptedCleanupClient: CleanupProviding, @unchecked Sendable {
        private var results: [Result<String, any Error>]
        private(set) var calls = 0
        init(_ results: [Result<String, any Error>]) { self.results = results }
        func cleanup(rawText: String, prompt: String, apiKey: String) async throws -> String {
            calls += 1
            return try results.removeFirst().get()
        }
    }

    // MARK: - Fixtures (ephemeral storage, as in DictationCoordinatorMetaGatingTests)

    private func makeCoordinator(
        backend: (any TranscriptionBackend)? = nil,
        cleanupClient: any CleanupProviding = CleanupClient()
    ) -> DictationCoordinator {
        let name = "com.lore.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DictationRetryTests-\(UUID().uuidString)", isDirectory: true)
        return DictationCoordinator(
            history: DictationHistory(
                defaults: defaults,
                entriesDirectory: tmp.appendingPathComponent("entries"),
                audioDirectory: tmp.appendingPathComponent("audio")
            ),
            cleanupClient: cleanupClient,
            backend: backend
        )
    }

    private func makeSettings(apiKey: String) -> AppSettings {
        let name = "com.lore.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let storage = SettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DictationRetryTests"),
            legacyNotesDirectories: [],
            runMigrations: false
        )
        let settings = SettingsStore(storage: storage)
        settings.openaiApiKey = apiKey
        return settings
    }

    /// Save `sampleCount` samples of audio and add a history entry pointing at
    /// them, so `retryTranscription` reaches the chunk loop with the stub backend.
    private func addAudioEntry(
        to coordinator: DictationCoordinator, sampleCount: Int
    ) -> DictationHistoryEntry {
        let samples = [Float](repeating: 0.05, count: sampleCount)
        let entry = DictationHistoryEntry(
            durationSeconds: Double(sampleCount) / 16000.0,
            audioFilename: coordinator.history.saveAudio(samples)
        )
        coordinator.history.add(entry)
        return entry
    }

    // MARK: - Diag stream inspection (the shared test store, delta since a mark)

    /// Fence, then mark. Identical consecutive events share one record (#149), so
    /// without the fence a test's first event could fold into the previous test's
    /// last one and become invisible behind the mark.
    private func diagMark() -> Int {
        Self.nextFenceBuild += 1
        DiagStore.record(.appLaunched(build: Self.nextFenceBuild))
        return DiagStore.shared.recent(DiagStore.capacity).count
    }

    private func events(since mark: Int) -> [DiagEvent] {
        Array(DiagStore.shared.recent(DiagStore.capacity).dropFirst(mark)).occurrenceEvents
    }

    private func lastTranscribed(since mark: Int) -> (chunks: Int, failedChunks: Int)? {
        for event in events(since: mark).reversed() {
            if case .transcribed(let chunks, let failedChunks, _, _, _) = event {
                return (chunks, failedChunks)
            }
        }
        return nil
    }

    private func apiCallOutcomes(since mark: Int) -> [DiagEvent.Outcome] {
        events(since: mark).compactMap {
            if case .apiCall(_, let outcome, _, _) = $0 { return outcome }
            return nil
        }
    }

    // MARK: - Transcription chunk retries

    func testChunkFailingOnceThenSucceedingYieldsFullText() async {
        let backend = ScriptedBackend([
            .failure(TranscriptionBackendError.notPrepared),
            .success("hello there"),
        ])
        let coordinator = makeCoordinator(backend: backend)
        let entry = addAudioEntry(to: coordinator, sampleCount: 20_000)
        let mark = diagMark()

        await coordinator.retryTranscription(entryID: entry.id)

        let updated = coordinator.history.entries.first { $0.id == entry.id }!
        XCTAssertEqual(updated.rawText, "hello there")
        XCTAssertEqual(updated.status, .transcribed)
        XCTAssertEqual(backend.calls, 2)
        XCTAssertEqual(lastTranscribed(since: mark)?.failedChunks, 0)
    }

    func testChunkFailingAllAttemptsIsSkippedRestSurvives() async {
        // 500k samples → two chunks (480k + 20k). Chunk 1 burns all 3 attempts
        // and is lost; chunk 2 succeeds — its words are the whole transcript.
        let backend = ScriptedBackend([
            .failure(TranscriptionBackendError.notPrepared),
            .failure(TranscriptionBackendError.notPrepared),
            .failure(TranscriptionBackendError.notPrepared),
            .success("tail words"),
        ])
        let coordinator = makeCoordinator(backend: backend)
        let entry = addAudioEntry(to: coordinator, sampleCount: 500_000)
        let mark = diagMark()

        await coordinator.retryTranscription(entryID: entry.id)

        let updated = coordinator.history.entries.first { $0.id == entry.id }!
        XCTAssertEqual(updated.rawText, "tail words")
        XCTAssertEqual(backend.calls, 4)
        let transcribed = lastTranscribed(since: mark)
        XCTAssertEqual(transcribed?.chunks, 2)
        XCTAssertEqual(transcribed?.failedChunks, 1)
    }

    func testEmptySuccessfulChunkIsNotRetried() async {
        let backend = ScriptedBackend([.success("")])
        let coordinator = makeCoordinator(backend: backend)
        let entry = addAudioEntry(to: coordinator, sampleCount: 20_000)
        let mark = diagMark()

        await coordinator.retryTranscription(entryID: entry.id)

        XCTAssertEqual(backend.calls, 1, "silence is a success, not a retryable failure")
        XCTAssertEqual(lastTranscribed(since: mark)?.failedChunks, 0)
        let updated = coordinator.history.entries.first { $0.id == entry.id }!
        XCTAssertEqual(updated.status, .failed)
    }

    // MARK: - Cleanup retries

    func testCleanupTransientFailureThenSuccessNoFallback() async {
        let client = ScriptedCleanupClient([
            .failure(URLError(.timedOut)),
            .success("Cleaned."),
        ])
        let coordinator = makeCoordinator(cleanupClient: client)
        coordinator.settings = makeSettings(apiKey: "sk-test")
        var entry = DictationHistoryEntry(durationSeconds: 1)
        entry.status = .transcribed
        entry.rawText = "hello world"
        let mark = diagMark()

        let ok = await coordinator.cleanupEntry(
            &entry, rawText: "hello world", prompt: "clean it up",
            failureMessage: DictationCoordinator.cleanupFailedPastedRaw,
            endpoint: .cleanup
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(entry.cleanedText, "Cleaned.")
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(apiCallOutcomes(since: mark), [.failed, .ok])
    }

    func testCleanup401FailsImmediatelyWithoutRetry() async {
        let client = ScriptedCleanupClient([
            .failure(CleanupClient.CleanupError.apiError(401)),
        ])
        let coordinator = makeCoordinator(cleanupClient: client)
        coordinator.settings = makeSettings(apiKey: "sk-revoked")
        var entry = DictationHistoryEntry(durationSeconds: 1)
        entry.status = .transcribed
        entry.rawText = "hello world"
        let mark = diagMark()

        let ok = await coordinator.cleanupEntry(
            &entry, rawText: "hello world", prompt: "clean it up",
            failureMessage: DictationCoordinator.cleanupFailedPastedRaw,
            endpoint: .cleanup
        )

        XCTAssertFalse(ok)
        XCTAssertEqual(client.calls, 1, "a 4xx must not be retried")
        XCTAssertEqual(coordinator.lastError, DictationCoordinator.cleanupFailedPastedRaw)
        XCTAssertEqual(apiCallOutcomes(since: mark), [.failed])
        XCTAssertNil(entry.cleanedText)
    }

    func testCleanupExhaustedTransientRetriesFallsBack() async {
        let client = ScriptedCleanupClient([
            .failure(URLError(.networkConnectionLost)),
            .failure(CleanupClient.CleanupError.apiError(500)),
            .failure(URLError(.timedOut)),
        ])
        let coordinator = makeCoordinator(cleanupClient: client)
        coordinator.settings = makeSettings(apiKey: "sk-test")
        var entry = DictationHistoryEntry(durationSeconds: 1)
        entry.status = .transcribed
        entry.rawText = "hello world"
        let mark = diagMark()

        let ok = await coordinator.cleanupEntry(
            &entry, rawText: "hello world", prompt: "clean it up",
            failureMessage: DictationCoordinator.cleanupFailedPastedRaw,
            endpoint: .cleanup
        )

        XCTAssertFalse(ok)
        XCTAssertEqual(client.calls, 3)
        XCTAssertEqual(coordinator.lastError, DictationCoordinator.cleanupFailedPastedRaw)
        XCTAssertEqual(apiCallOutcomes(since: mark), [.failed, .failed, .failed])
        XCTAssertNil(entry.cleanedText)
        XCTAssertEqual(entry.status, .transcribed)
    }

    // MARK: - Transient predicate

    func testTransientPredicateClassifiesStatuses() {
        for code: URLError.Code in [
            .timedOut, .networkConnectionLost, .notConnectedToInternet,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        ] {
            XCTAssertTrue(DictationCoordinator.isTransientCleanupError(URLError(code)), "\(code)")
        }
        // URLError is not transient wholesale: cancellation and
        // structurally-broken requests must not be retried.
        XCTAssertFalse(DictationCoordinator.isTransientCleanupError(URLError(.cancelled)))
        XCTAssertFalse(DictationCoordinator.isTransientCleanupError(URLError(.badURL)))
        XCTAssertFalse(DictationCoordinator.isTransientCleanupError(URLError(.userAuthenticationRequired)))
        XCTAssertTrue(DictationCoordinator.isTransientCleanupError(CleanupClient.CleanupError.apiError(429)))
        XCTAssertTrue(DictationCoordinator.isTransientCleanupError(CleanupClient.CleanupError.apiError(503)))
        XCTAssertFalse(DictationCoordinator.isTransientCleanupError(CleanupClient.CleanupError.apiError(400)))
        XCTAssertFalse(DictationCoordinator.isTransientCleanupError(CleanupClient.CleanupError.apiError(401)))
    }

    // MARK: - Cancellation is never transient

    private final class AttemptCounter: @unchecked Sendable {
        var n = 0
    }

    func testCancellationDuringBackoffPropagatesWithoutAnotherAttempt() async {
        let counter = AttemptCounter()
        let task = Task { @MainActor () throws -> String in
            try await DictationCoordinator.withRetries(
                attempts: 3, backoff: [.seconds(10), .seconds(10)]
            ) {
                counter.n += 1
                throw URLError(.timedOut)
            }
        }
        // Let attempt 1 fail and enter the first backoff, then cancel into it.
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let result = await task.result
        XCTAssertEqual(counter.n, 1, "cancellation during backoff must not fire another attempt")
        guard case .failure(let error) = result else {
            return XCTFail("cancelled retry must throw")
        }
        XCTAssertTrue(error is CancellationError)
    }

    func testCancellationErrorNeverRetriedEvenWithAlwaysTransientPredicate() async {
        // The chunk loop's configuration: no predicate, everything transient.
        let counter = AttemptCounter()
        do {
            _ = try await DictationCoordinator.withRetries(attempts: 3) {
                counter.n += 1
                throw CancellationError()
            } as String
            XCTFail("must rethrow")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(counter.n, 1)
    }
}
