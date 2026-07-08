import XCTest
@testable import LoreKit

/// Ring-buffer, persistence and concurrency behaviour of the diagnostic store (#82).
final class DiagStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DiagStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private var eventsURL: URL { directory.appendingPathComponent("events.json") }

    // MARK: - Ring buffer

    func testRingBufferEvictsOldestBeyondCapacity() {
        let store = DiagStore(directory: directory)
        let overflow = 50
        let total = DiagStore.capacity + overflow

        for i in 0..<total {
            store.record(.captureGaveUp(attempts: i))
        }

        let all = store.recent(total)
        XCTAssertEqual(all.count, DiagStore.capacity, "ring must never exceed capacity")

        // The first `overflow` events are gone; the ring starts at `overflow`.
        XCTAssertEqual(all.first?.event, .captureGaveUp(attempts: overflow))
        XCTAssertEqual(all.last?.event, .captureGaveUp(attempts: total - 1))
    }

    func testRecentReturnsChronologicalSuffix() {
        let store = DiagStore(directory: directory)
        for i in 0..<10 { store.record(.captureGaveUp(attempts: i)) }

        let last3 = store.recent(3)
        XCTAssertEqual(last3.map(\.event), [
            .captureGaveUp(attempts: 7),
            .captureGaveUp(attempts: 8),
            .captureGaveUp(attempts: 9),
        ])
    }

    func testRecentClampsToAvailableCount() {
        let store = DiagStore(directory: directory)
        store.record(.micRecovered)
        XCTAssertEqual(store.recent(500).count, 1)
    }

    func testLastWhereFindsLatestMatchingEvent() {
        let store = DiagStore(directory: directory)
        store.record(.captureFailed(stage: .startDevice, osStatus: -10875))
        store.record(.micRecovered)
        store.record(.captureStart(deviceKind: .builtIn, ms: 42))
        store.record(.micRecovered)

        let latest = store.last { $0.event.caseName == "captureStart" }
        XCTAssertEqual(latest?.event, .captureStart(deviceKind: .builtIn, ms: 42))
    }

    func testLastWhereReturnsNilWhenNoMatch() {
        let store = DiagStore(directory: directory)
        store.record(.micRecovered)
        XCTAssertNil(store.last { $0.event.caseName == "tapCreate" })
    }

    func testSubsystemIsDerivedFromEvent() {
        let store = DiagStore(directory: directory)
        store.record(.tapDisabledByOS)
        XCTAssertEqual(store.recent(1).first?.subsystem, .input)
    }

    // MARK: - Persistence

    func testPersistenceRoundTripSurvivesRestart() {
        let store = DiagStore(directory: directory)
        store.record(.appLaunched(build: 1234))
        store.record(.modelLoad(model: .asr, outcome: .ok, seconds: 2.5, fromCache: true))
        store.record(.apiCall(endpoint: .cleanup, outcome: .failed, httpStatus: 429, ms: 900))
        store.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: eventsURL.path))

        // A fresh store over the same directory is what a relaunch looks like.
        let reloaded = DiagStore(directory: directory)
        XCTAssertEqual(reloaded.recent(10).map(\.event), [
            .appLaunched(build: 1234),
            .modelLoad(model: .asr, outcome: .ok, seconds: 2.5, fromCache: true),
            .apiCall(endpoint: .cleanup, outcome: .failed, httpStatus: 429, ms: 900),
        ])
    }

    func testPersistenceRoundTripPreservesTimestamps() {
        let store = DiagStore(directory: directory)
        store.record(.micRecovered)
        store.flush()
        let original = store.recent(1)[0].at

        let reloaded = DiagStore(directory: directory).recent(1)[0].at
        // ISO8601 has second resolution; equality within a second is the contract.
        XCTAssertEqual(original.timeIntervalSince1970, reloaded.timeIntervalSince1970, accuracy: 1.0)
    }

    func testFlushCreatesDirectoryIfMissing() throws {
        try FileManager.default.removeItem(at: directory)
        let store = DiagStore(directory: directory)
        store.record(.micRecovered)
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventsURL.path))
    }

    func testReloadIsCappedAtCapacity() throws {
        let store = DiagStore(directory: directory)
        for i in 0..<(DiagStore.capacity + 10) { store.record(.captureGaveUp(attempts: i)) }
        store.flush()

        let reloaded = DiagStore(directory: directory)
        XCTAssertEqual(reloaded.recent(DiagStore.capacity * 2).count, DiagStore.capacity)
    }

    func testRecordSchedulesAsyncFlushWithoutExplicitCall() {
        let store = DiagStore(directory: directory)
        store.record(.micRecovered)

        // The coalesced flush lands within ~1s; poll rather than sleep blindly.
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: eventsURL.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: eventsURL.path),
            "record() must schedule a background flush without an explicit flush() call"
        )
    }

    // MARK: - Corrupt-file recovery

    func testCorruptFileIsMovedAsideNotRebuiltOver() throws {
        try Data("{ this is not json".utf8).write(to: eventsURL)

        let store = DiagStore(directory: directory)

        // Prior contents preserved under `.corrupt`, never destroyed.
        let aside = directory.appendingPathComponent("events.json.corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ this is not json")

        // The store starts fresh, and says so.
        XCTAssertEqual(store.recent(10).map(\.event), [.corruptFileAside(artifact: .eventsJSON)])
    }

    func testRepeatCorruptionKeepsEarlierAsides() throws {
        try Data("corrupt one".utf8).write(to: eventsURL)
        _ = DiagStore(directory: directory)

        try Data("corrupt two".utf8).write(to: eventsURL)
        _ = DiagStore(directory: directory)

        let first = directory.appendingPathComponent("events.json.corrupt")
        let second = directory.appendingPathComponent("events.json.corrupt.1")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "corrupt one")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "corrupt two")
    }

    func testMissingFileLoadsEmptyWithoutAside() {
        let store = DiagStore(directory: directory)
        XCTAssertTrue(store.recent(10).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("events.json.corrupt").path
            )
        )
    }

    func testStoreRecoversAfterCorruptionAndPersistsAgain() throws {
        try Data("garbage".utf8).write(to: eventsURL)
        let store = DiagStore(directory: directory)
        store.record(.micRecovered)
        store.flush()

        let reloaded = DiagStore(directory: directory)
        XCTAssertEqual(reloaded.recent(10).map(\.event), [
            .corruptFileAside(artifact: .eventsJSON),
            .micRecovered,
        ])
    }

    // MARK: - Concurrency

    /// `record()` is called from the CoreAudio listener queue, the HAL queue and
    /// MainActor alike. Nothing may be lost, and nothing may deadlock.
    func testConcurrentRecordFromManyQueuesLosesNothing() {
        let store = DiagStore(directory: directory)
        let queues = (0..<8).map { DispatchQueue(label: "diag.test.\($0)") }
        let perQueue = 200
        let group = DispatchGroup()

        for queue in queues {
            queue.async(group: group) {
                for i in 0..<perQueue {
                    store.record(.captureGaveUp(attempts: i))
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

        let total = queues.count * perQueue
        XCTAssertLessThanOrEqual(total, DiagStore.capacity)
        XCTAssertEqual(store.recent(DiagStore.capacity).count, total)
    }

    func testConcurrentRecordAndReadDoNotDeadlock() {
        let store = DiagStore(directory: directory)
        let group = DispatchGroup()

        DispatchQueue.global().async(group: group) {
            for i in 0..<500 { store.record(.captureGaveUp(attempts: i)) }
        }
        DispatchQueue.global().async(group: group) {
            for _ in 0..<500 {
                _ = store.recent(10)
                _ = store.last { $0.subsystem == .audio }
            }
        }
        DispatchQueue.global().async(group: group) {
            for _ in 0..<20 { store.flush() }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "record/read/flush must not deadlock")
    }

    func testConcurrentRecordOverflowStaysAtCapacity() {
        let store = DiagStore(directory: directory)
        let group = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global().async(group: group) {
                for i in 0..<1000 { store.record(.captureGaveUp(attempts: i)) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(store.recent(DiagStore.capacity * 2).count, DiagStore.capacity)
    }
}
