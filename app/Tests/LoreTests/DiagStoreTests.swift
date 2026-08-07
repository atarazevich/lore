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

    // MARK: - Coalescing (#149)

    /// Three hours of an event firing every five seconds costs one slot, and the
    /// history before it survives (#149).
    func testARepeatingEventDoesNotEvictTheHistoryBeforeIt() {
        let store = DiagStore(directory: directory)
        store.record(.appLaunched(build: 283))
        store.record(.modelLoad(model: .asr, outcome: .ok, seconds: 0.78, fromCache: false))
        store.record(.permissionTransition(permission: .inputMonitoring, granted: false))

        // Three hours at the observed cadence.
        for _ in 0..<2160 { store.record(.tapCreate(outcome: .failed, osStatus: nil)) }

        let all = store.recent(DiagStore.capacity)
        XCTAssertEqual(all.count, 4, "three pre-failure facts plus one slot for the loop")
        XCTAssertEqual(all[0].event, .appLaunched(build: 283))
        XCTAssertEqual(all[1].event, .modelLoad(model: .asr, outcome: .ok, seconds: 0.78, fromCache: false))
        XCTAssertEqual(all[2].event, .permissionTransition(permission: .inputMonitoring, granted: false))
        XCTAssertEqual(all[3].occurrences, 2160)
    }

    /// Only the newest record folds, so the ring stays a timeline.
    func testARepeatAfterADifferentEventTakesANewSlot() {
        let store = DiagStore(directory: directory)
        store.record(.micRecovered)
        store.record(.tapDisabledByOS)
        store.record(.micRecovered)

        XCTAssertEqual(store.recent(DiagStore.capacity).map(\.event),
                       [.micRecovered, .tapDisabledByOS, .micRecovered])
    }

    /// A fold keeps the first occurrence's slot and timestamp and carries the
    /// last — the span, not just a tally.
    func testACoalescedRecordCarriesFirstAndLastTimestamps() {
        let store = DiagStore(directory: directory)
        store.record(.dictationZeroFrames)
        let first = store.recent(1)[0].at
        store.record(.dictationZeroFrames)
        store.record(.dictationZeroFrames)

        let record = store.recent(1)[0]
        XCTAssertEqual(record.occurrences, 3)
        XCTAssertEqual(record.at, first, "the record stays at its first occurrence")
        let last = try! XCTUnwrap(record.until)
        XCTAssertGreaterThanOrEqual(last, first)
        XCTAssertEqual(record.lastAt, last)
    }

    /// A single occurrence stays exactly what it was — no count, no until, and
    /// events.json unchanged for the ordinary case.
    func testASingleOccurrenceCarriesNoCoalescingFields() throws {
        let store = DiagStore(directory: directory)
        store.record(.micRecovered)
        let record = store.recent(1)[0]
        XCTAssertEqual(record.occurrences, 1)
        XCTAssertNil(record.until)
        XCTAssertEqual(record.lastAt, record.at)

        store.flush()
        let json = try String(contentsOf: eventsURL, encoding: .utf8)
        XCTAssertFalse(json.contains("\"count\""))
        XCTAssertFalse(json.contains("\"until\""))
    }

    /// A count survives the disk round trip, and re-loading an already-coalesced
    /// file does not silently drop a run's tally.
    func testCoalescedCountsSurviveAReload() {
        let store = DiagStore(directory: directory)
        store.record(.appLaunched(build: 7))
        for _ in 0..<40 { store.record(.historyWriteFailed) }
        store.flush()

        let reloaded = DiagStore(directory: directory).recent(DiagStore.capacity)
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded[1].event, .historyWriteFailed)
        XCTAssertEqual(reloaded[1].occurrences, 40)
    }

    /// A folded run stays the newest record, so the health panel still reads the
    /// state the machine is actually in.
    func testLastWhereStillFindsAFoldedRunAsTheLatest() {
        let store = DiagStore(directory: directory)
        store.record(.systemAudioCapture(outcome: .ok, osStatus: nil))
        for _ in 0..<5 { store.record(.systemAudioCapture(outcome: .failed, osStatus: -1)) }

        let latest = store.last { $0.event.caseName == "systemAudioCapture" }
        XCTAssertEqual(latest?.event, .systemAudioCapture(outcome: .failed, osStatus: -1))
        XCTAssertEqual(latest?.occurrences, 5)
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

        // Eight queues emit the same payloads, so occurrences fold into fewer
        // records (#149). "Nothing lost" is therefore the sum of the counts, not
        // the number of slots — which is the whole point of the fold.
        let total = queues.count * perQueue
        XCTAssertLessThanOrEqual(total, DiagStore.capacity)
        XCTAssertEqual(store.recent(DiagStore.capacity).occurrences, total)
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
        XCTAssertLessThanOrEqual(store.recent(DiagStore.capacity * 2).count, DiagStore.capacity)
    }
}
