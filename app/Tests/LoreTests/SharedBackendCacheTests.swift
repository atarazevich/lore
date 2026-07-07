import XCTest
@testable import LoreKit

/// Verifies SharedBackendCache dedups concurrent `prepare()` calls so the launch
/// prewarm racing a real first transcription loads the model exactly once (#81).
@MainActor
final class SharedBackendCacheTests: XCTestCase {

    func testConcurrentPrepareBuildsBackendOnce() async throws {
        let builds = BuildCounter()
        let cache = SharedBackendCache(makeBackend: {
            builds.increment()
            return StubTranscriptionBackend(yieldDuringPrepare: true)
        })

        // Two callers race; both should observe a single build.
        async let a: Void = cache.prepare()
        async let b: Void = cache.prepare()
        _ = try await (a, b)

        XCTAssertEqual(builds.count, 1, "concurrent prepare must build the backend exactly once")
        XCTAssertTrue(cache.isReady)
        XCTAssertNotNil(cache.backend)
    }

    func testPrepareAfterCompletionShortCircuits() async throws {
        let builds = BuildCounter()
        let cache = SharedBackendCache(makeBackend: {
            builds.increment()
            return StubTranscriptionBackend(yieldDuringPrepare: true)
        })

        try await cache.prepare()
        try await cache.prepare()

        XCTAssertEqual(builds.count, 1, "a completed cache must not rebuild on later prepare()")
    }

    func testPrepareRebuildsAfterFailure() async throws {
        let builds = BuildCounter()
        let cache = SharedBackendCache(makeBackend: {
            let n = builds.increment()
            return StubTranscriptionBackend(failOnPrepare: n == 1, yieldDuringPrepare: true)
        })

        // First load fails — the in-flight task must clear so a retry can rebuild.
        do {
            try await cache.prepare()
            XCTFail("Expected first prepare to throw")
        } catch is StubBackendError {
            // expected
        }
        XCTAssertFalse(cache.isReady)

        // Retry succeeds and caches.
        try await cache.prepare()
        XCTAssertEqual(builds.count, 2)
        XCTAssertTrue(cache.isReady)
    }
}

// MARK: - Test helpers

private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    @discardableResult
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
