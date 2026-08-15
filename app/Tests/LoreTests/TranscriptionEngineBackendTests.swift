import XCTest
@testable import LoreKit

/// The meeting's model path (#169). A meeting must draw its mic leg from the
/// shared cache — the app's single prepared instance — instead of building a
/// second copy of the model beside it, whatever the timing.
///
/// Drives `acquireASRBackends()` rather than `start()`: that is the whole model
/// path, minus the microphone permission, the audio device and the VAD model
/// that `start()` would also need.
@MainActor
final class TranscriptionEngineBackendTests: XCTestCase {

    // MARK: - The duplicate this issue was about

    /// A meeting started while the launch warm-up is still loading shares that
    /// load: one build, and the mic leg is the shared instance itself.
    /// Whichever of the two reaches the cache first owns the load and the other
    /// joins it — the claim is that there is only ever one.
    func testMeetingStartedDuringWarmUpJoinsTheSharedLoad() async throws {
        let builds = BuildCounter()
        let cache = SharedBackendCache(makeBackend: {
            builds.increment()
            return StubTranscriptionBackend(yieldDuringPrepare: true)
        })
        let engine = makeEngine(cache: cache)

        // The launch warm-up, in flight — not awaited, exactly as at launch.
        let warmUp = Task { try await cache.prepare() }
        await Task.yield()
        // …and the meeting, arriving during it.
        try await engine.acquireASRBackends()
        _ = try await warmUp.value

        XCTAssertEqual(builds.count, 1, "a meeting during the warm-up must not load a second model")
        XCTAssertIdentical(
            engine.micBackend as AnyObject,
            cache.backend as AnyObject,
            "the mic leg must be the shared instance, not a copy of it"
        )
    }

    /// The cold case: nothing warm anywhere. The mic leg still comes from the
    /// cache, so dictation and the meeting share the one instance afterwards.
    func testColdMeetingLoadsThroughTheSharedCache() async throws {
        let builds = BuildCounter()
        let cache = SharedBackendCache(makeBackend: {
            builds.increment()
            return StubTranscriptionBackend()
        })
        let engine = makeEngine(cache: cache)

        try await engine.acquireASRBackends()

        XCTAssertEqual(builds.count, 1)
        XCTAssertIdentical(engine.micBackend as AnyObject, cache.backend as AnyObject)
    }

    /// A second meeting in the same session loads nothing: neither leg.
    func testSecondMeetingLoadsNothing() async throws {
        let builds = BuildCounter()
        let systemBuilds = BuildCounter()
        let cache = SharedBackendCache(makeBackend: {
            builds.increment()
            return StubTranscriptionBackend()
        })
        let engine = makeEngine(cache: cache, systemBackend: {
            systemBuilds.increment()
            return StubTranscriptionBackend()
        })

        try await engine.acquireASRBackends()
        let firstMic = engine.micBackend as AnyObject
        let firstSystem = engine.systemBackend as AnyObject

        await engine.finalize()
        try await engine.acquireASRBackends()

        XCTAssertEqual(builds.count, 1, "the shared instance must survive a meeting ending")
        XCTAssertEqual(systemBuilds.count, 1, "the system leg must survive a meeting ending")
        XCTAssertIdentical(engine.micBackend as AnyObject, firstMic)
        XCTAssertIdentical(engine.systemBackend as AnyObject, firstSystem)
    }

    /// Ending a meeting gives up the borrowed references only — dictation's
    /// copy of the same instance keeps working.
    func testFinalizeReleasesTheBorrowNotTheSharedInstance() async throws {
        let cache = SharedBackendCache(makeBackend: { StubTranscriptionBackend() })
        let engine = makeEngine(cache: cache)

        try await engine.acquireASRBackends()
        await engine.finalize()

        XCTAssertNil(engine.micBackend)
        XCTAssertTrue(cache.isReady, "a meeting ending must not tear down the shared instance")
    }

    // MARK: - What the events say

    /// One cold load for the whole app, cache hits after it — the check the
    /// issue asks for against `events.json`.
    func testEventsReportOneColdLoadThenHits() async throws {
        let cache = SharedBackendCache(makeBackend: { StubTranscriptionBackend(yieldDuringPrepare: true) })
        let engine = makeEngine(cache: cache)

        let recorded = try await asrLoads {
            let warmUp = Task { try await cache.prepare() }
            await Task.yield()
            try await engine.acquireASRBackends()   // shares the warm-up's load
            _ = try await warmUp.value
            await engine.finalize()
            try await engine.acquireASRBackends()   // second meeting
        }

        XCTAssertEqual(
            recorded.filter { $0.outcome == .ok && !$0.fromCache }.count, 1,
            "exactly one cold ASR load: \(recorded)"
        )
        XCTAssertEqual(
            recorded.filter { $0.outcome == .ok && $0.fromCache }.count, 2,
            "the meeting that joined the load and the second meeting are both hits: \(recorded)"
        )
    }

    /// A system-leg build that fails still reports transcription as broken —
    /// the health surface has no other source for that (#151).
    func testSystemLegFailureIsReported() async throws {
        let cache = SharedBackendCache(makeBackend: { StubTranscriptionBackend() })
        let engine = makeEngine(cache: cache, systemBackend: { StubTranscriptionBackend(failOnPrepare: true) })

        let recorded = await asrLoads {
            do {
                try await engine.acquireASRBackends()
                XCTFail("expected the system leg to throw")
            } catch is StubBackendError {
                // expected
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(recorded.filter { $0.outcome == .failed }.count, 1, "one failure: \(recorded)")
    }

    // MARK: - Helpers

    private func makeEngine(
        cache: SharedBackendCache,
        systemBackend: @escaping @Sendable () -> any TranscriptionBackend = { StubTranscriptionBackend() }
    ) -> TranscriptionEngine {
        TranscriptionEngine(
            transcriptStore: TranscriptStore(),
            settings: Self.makeSettings(),
            sharedBackendCache: cache,
            makeSystemBackend: systemBackend
        )
    }

    /// Isolated settings — never the user's real defaults or Keychain.
    private static func makeSettings() -> AppSettings {
        let suiteName = "TranscriptionEngineBackendTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return AppSettings(storage: AppSettingsStorage(
            defaults: suite,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("TranscriptionEngineBackendTests"),
            legacyNotesDirectories: [],
            runMigrations: false
        ))
    }

    /// The ASR `modelLoad` events `body` caused, in order. Listens at the
    /// store's observer seam rather than reading the ring: the ring is the
    /// machine's real one, where an old event can be evicted mid-test and skew
    /// a before/after count. `seconds` varies per run, so only the two fields
    /// that carry the claim come back.
    ///
    /// Nothing else installs an observer in tests — clearing it afterwards
    /// leaves the store exactly as found.
    private func asrLoads(
        during body: () async throws -> Void
    ) async rethrows -> [(outcome: DiagEvent.Outcome, fromCache: Bool)] {
        let collector = DiagEventCollector()
        DiagStore.shared.setObserver { collector.record($0) }
        defer { DiagStore.shared.setObserver(nil) }
        try await body()
        return collector.asrLoads
    }
}

private final class DiagEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiagEvent] = []

    func record(_ event: DiagEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var asrLoads: [(outcome: DiagEvent.Outcome, fromCache: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { event in
            guard case .modelLoad(.asr, let outcome, _, let fromCache) = event else { return nil }
            return (outcome, fromCache)
        }
    }
}
