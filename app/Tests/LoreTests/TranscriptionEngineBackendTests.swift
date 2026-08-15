import AVFoundation
import os
import XCTest
@testable import LoreKit

/// The meeting's model path (#169). A meeting must draw its mic leg from the
/// shared cache — the app's single prepared instance — instead of building a
/// second copy of the model beside it, whatever the timing.
///
/// Most tests drive `acquireASRBackends()`: that is the whole model path, minus
/// the microphone permission, the audio device and the VAD model that `start()`
/// would also need. `testStartAsksTheSharedCache…` pins that `start()` really
/// goes through it, since a peek re-introduced there would leave the rest green.
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
        let shared = try await warmUp.value

        XCTAssertEqual(builds.count, 1, "a meeting during the warm-up must not load a second model")
        XCTAssertIdentical(
            engine.micBackend as AnyObject, shared as AnyObject,
            "the mic leg must be the shared instance, not a copy of it"
        )
    }

    /// The cold case and every meeting after it: one build per leg for the whole
    /// app. Ending a meeting gives up the borrowed references only — the shared
    /// instance dictation is also using stays, and so does the system leg.
    func testTheSharedInstanceOutlivesTheMeetingsThatBorrowIt() async throws {
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
        XCTAssertEqual(builds.count, 1, "a cold meeting loads its mic leg through the cache")
        let shared = try await cache.prepare() as AnyObject
        XCTAssertIdentical(firstMic, shared, "the mic leg must be the shared instance, not a copy of it")

        await engine.finalize()
        XCTAssertNil(engine.micBackend)
        XCTAssertNil(engine.systemBackend)
        XCTAssertTrue(cache.isReady, "a meeting ending must not tear down the shared instance")

        try await engine.acquireASRBackends()
        XCTAssertEqual(builds.count, 1, "the shared instance must survive a meeting ending")
        XCTAssertEqual(systemBuilds.count, 1, "the system leg must survive a meeting ending")
        XCTAssertIdentical(engine.micBackend as AnyObject, firstMic)
        XCTAssertIdentical(engine.systemBackend as AnyObject, firstSystem)
    }

    /// `start()` reaches the cache, and a stop that lands inside the load — a
    /// download can run for minutes — leaves no capture behind it.
    func testStartAsksTheSharedCacheAndAStopDuringTheLoadBringsNoCaptureUp() async throws {
        let builds = BuildCounter()
        let stub = StubTranscriptionBackend()
        let cache = SharedBackendCache(makeBackend: {
            builds.increment()
            return stub
        })
        let engine = makeEngine(cache: cache, micAuthorization: .authorized)
        // The user stops the meeting while the model is still loading.
        stub.duringPrepare = { [weak engine] in engine?.stop() }
        // Past the download gate: on a machine with no model on disk, start()
        // would otherwise return before loading anything.
        engine.downloadConfirmed = true

        await engine.start()

        XCTAssertEqual(builds.count, 1, "start() must take the mic leg from the shared cache")
        XCTAssertFalse(engine.isRunning, "a stop during the load must not be resumed over")
        XCTAssertNil(engine.micBackend, "an abandoned start holds no borrowed backend")
        XCTAssertEqual(engine.assetStatus, "Ready")
    }

    // MARK: - What the events say

    /// One real load per instance — the shared one, and the meeting's own
    /// system leg — and a hit for every caller served without loading. That is
    /// the reading `events.json` has to support: cold loads count the copies of
    /// the model in memory, hits count the callers that needed none.
    func testEventsReportOneColdLoadPerInstanceThenHits() async throws {
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
            recorded.filter { $0.outcome == .ok && !$0.fromCache }.count, 2,
            "one cold load each for the shared instance and the system leg: \(recorded)"
        )
        XCTAssertEqual(
            recorded.filter { $0.outcome == .ok && $0.fromCache }.count, 2,
            "the meeting that joined the load and the second meeting are both hits: \(recorded)"
        )
    }

    /// A system-leg build that fails reports transcription as broken — the
    /// health surface has no other source for that (#151). Its success reports
    /// too (the test above counts it): the claim has to be able to clear.
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
        systemBackend: @escaping @Sendable () -> any TranscriptionBackend = { StubTranscriptionBackend() },
        micAuthorization: AVAuthorizationStatus = .denied
    ) -> TranscriptionEngine {
        TranscriptionEngine(
            transcriptStore: TranscriptStore(),
            settings: isolatedSettings("TranscriptionEngineBackendTests"),
            sharedBackendCache: cache,
            makeSystemBackend: systemBackend,
            micAuthorization: { micAuthorization }
        )
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
        let events = OSAllocatedUnfairLock(initialState: [DiagEvent]())
        DiagStore.shared.setObserver { event in events.withLock { $0.append(event) } }
        defer { DiagStore.shared.setObserver(nil) }
        try await body()
        return events.withLock { $0 }.compactMap { event in
            guard case .modelLoad(.asr, let outcome, _, let fromCache) = event else { return nil }
            return (outcome, fromCache)
        }
    }
}
