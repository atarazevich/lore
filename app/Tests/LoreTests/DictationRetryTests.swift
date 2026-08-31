import XCTest
@testable import LoreKit

/// #103: transient failures get a small retry budget — 3 attempts per failed
/// transcription chunk (immediate), 3 for cleanup/translate (transient errors
/// only, backoff). Final-failure fallbacks and messages are unchanged.
@MainActor
final class DictationRetryTests: XCTestCase {

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

    // MARK: - Fixtures (ephemeral storage)

    private var storage: EphemeralDictation!

    override func setUp() async throws {
        try await super.setUp()
        storage = EphemeralDictation("DictationRetryTests")
    }

    override func tearDown() async throws {
        storage.tearDown()
        storage = nil
        try await super.tearDown()
    }

    private func makeCoordinator(
        backend: (any TranscriptionBackend)? = nil,
        cleanupClient: any CleanupProviding = CleanupClient()
    ) -> DictationCoordinator {
        storage.coordinator(backend: backend, cleanupClient: cleanupClient)
    }

    private func makeSettings(apiKey: String) -> AppSettings {
        isolatedSettings("DictationRetryTests", apiKey: apiKey)
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

    private func lastTranscribed(since mark: Int) -> (chunks: Int, failedChunks: Int)? {
        for event in DiagStream.events(since: mark).reversed() {
            if case .transcribed(let chunks, let failedChunks, _, _, _) = event {
                return (chunks, failedChunks)
            }
        }
        return nil
    }

    private func apiCallOutcomes(since mark: Int) -> [DiagEvent.Outcome] {
        DiagStream.events(since: mark).compactMap {
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
        let mark = DiagStream.mark()

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
        let mark = DiagStream.mark()

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
        let mark = DiagStream.mark()

        await coordinator.retryTranscription(entryID: entry.id)

        XCTAssertEqual(backend.calls, 1, "silence is a success, not a retryable failure")
        XCTAssertEqual(lastTranscribed(since: mark)?.failedChunks, 0)
        let updated = coordinator.history.entries.first { $0.id == entry.id }!
        XCTAssertEqual(updated.status, .failed)
    }

    /// A retry that comes back with nothing says so (#209, F2). It used to end
    /// in silence — the same lie the dictation path told with a green checkmark
    /// — and the history row is given the one sentence too, not an engineer's.
    func testARetryThatTranscribesToNothingShowsTheFace() async {
        let backend = ScriptedBackend([.success("")])
        let coordinator = makeCoordinator(backend: backend)
        let entry = addAudioEntry(to: coordinator, sampleCount: 20_000)

        await coordinator.retryTranscription(entryID: entry.id)

        XCTAssertEqual(coordinator.lastError, .nothingCameThrough)
        XCTAssertEqual(coordinator.state, .done, "the face needs the shape to stand in")
        let updated = coordinator.history.entries.first { $0.id == entry.id }!
        XCTAssertEqual(updated.status, .failed)
        XCTAssertEqual(updated.errorMessage, DictationFace.nothingCameThrough.sentence)
    }

    /// And one that comes back with words leaves no face behind it: the row it
    /// rewrote is the answer, and it is already on screen (#209, V-A).
    func testARetryThatSucceedsLeavesNoFace() async {
        let backend = ScriptedBackend([.success("hello there")])
        let coordinator = makeCoordinator(backend: backend)
        let entry = addAudioEntry(to: coordinator, sampleCount: 20_000)

        await coordinator.retryTranscription(entryID: entry.id)

        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(coordinator.state, .idle)
    }

    /// Silence over an entry that carries something is not nothing (#229). The
    /// retry re-composes from the entry's own items, so a row failed by the
    /// gate before the fix heals when it is asked again.
    func testARetryOverAnEntryThatCarriesItemsComposesThem() async {
        // `pasteText` reads the Copying switches live (#198), so the expected
        // string needs a store the owner's own Settings cannot decide.
        _ = isolatedRichInputDefaults("DictationRetryTests")
        defer { RichInputSettings.use(.standard) }
        let coordinator = makeCoordinator(backend: ScriptedBackend([.success("")]))
        var entry = addAudioEntry(to: coordinator, sampleCount: 20_000)
        entry.status = .failed
        entry.errorMessage = DictationFace.nothingCameThrough.sentence
        entry.items = [DictationItem(kind: .text, offset: 1, text: "the stack trace")]
        coordinator.history.update(entry)

        await coordinator.retryTranscription(entryID: entry.id)

        let updated = coordinator.history.entries.first { $0.id == entry.id }!
        XCTAssertEqual(updated.status, .transcribed)
        XCTAssertEqual(updated.rawText, "<copied>\nthe stack trace\n</copied>")
        XCTAssertNil(updated.errorMessage)
        XCTAssertNil(coordinator.lastError)
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
        let mark = DiagStream.mark()

        let ok = await coordinator.cleanupEntry(
            &entry, rawText: "hello world", prompt: "clean it up",
            failureMessage: .cleanupFailed,
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
        let mark = DiagStream.mark()

        let ok = await coordinator.cleanupEntry(
            &entry, rawText: "hello world", prompt: "clean it up",
            failureMessage: .cleanupFailed,
            endpoint: .cleanup
        )

        XCTAssertFalse(ok)
        XCTAssertEqual(client.calls, 1, "a 4xx must not be retried")
        XCTAssertEqual(coordinator.lastError, .cleanupFailed)
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
        let mark = DiagStream.mark()

        let ok = await coordinator.cleanupEntry(
            &entry, rawText: "hello world", prompt: "clean it up",
            failureMessage: .cleanupFailed,
            endpoint: .cleanup
        )

        XCTAssertFalse(ok)
        XCTAssertEqual(client.calls, 3)
        XCTAssertEqual(coordinator.lastError, .cleanupFailed)
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
