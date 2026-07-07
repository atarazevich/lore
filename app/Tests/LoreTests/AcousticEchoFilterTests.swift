import XCTest
@testable import LoreKit

/// Batch-path coverage for the shared echo rule (#59): the live paths are
/// covered via TranscriptStoreTests; `suppress` must apply the same
/// short-text strict branch to merged batch records.
final class AcousticEchoFilterTests: XCTestCase {

    private func record(_ text: String, speaker: Speaker, at timestamp: Date) -> SessionRecord {
        SessionRecord(speaker: speaker, text: text, timestamp: timestamp)
    }

    func testBatchShortExactDupDropped() {
        let now = Date()
        var mic = [record("Orders.", speaker: .you, at: now.addingTimeInterval(1.0))]
        let sys = [record("Orders.", speaker: .them, at: now)]

        AcousticEchoFilter.suppress(micRecords: &mic, against: sys)

        XCTAssertTrue(mic.isEmpty, "Short verbatim dup within 2s should be suppressed in batch")
    }

    func testBatchShortNonExactKept() {
        let now = Date()
        var mic = [record("Yeah.", speaker: .you, at: now.addingTimeInterval(0.5))]
        let sys = [record("yeah right", speaker: .them, at: now)]

        AcousticEchoFilter.suppress(micRecords: &mic, against: sys)

        XCTAssertEqual(mic.count, 1, "Short non-exact texts should never match")
    }

    func testBatchShortExactDupOutsideStrictWindowKept() {
        let now = Date()
        var mic = [record("Orders.", speaker: .you, at: now.addingTimeInterval(3.0))]
        let sys = [record("Orders.", speaker: .them, at: now)]

        AcousticEchoFilter.suppress(micRecords: &mic, against: sys)

        XCTAssertEqual(mic.count, 1, "Short exact dup outside 2s should be kept")
    }

    func testBatchLongTextBehaviorUnchanged() {
        let now = Date()
        var mic = [
            record("Нам нужен этот бандал для имплементации клиента", speaker: .you, at: now.addingTimeInterval(3.0)),
            record("Да согласен давай сделаем это завтра утром после обеда", speaker: .you, at: now.addingTimeInterval(1.0)),
        ]
        let sys = [record("Нам нужен этот бандал для имплементации клиента", speaker: .them, at: now)]

        AcousticEchoFilter.suppress(micRecords: &mic, against: sys)

        XCTAssertEqual(mic.count, 1, "Long-text echo within 4s window still drops; different speech kept")
        XCTAssertEqual(mic.first?.text, "Да согласен давай сделаем это завтра утром после обеда")
    }

    func testMatchesShortStrictBranchAcceptsNegativeDeltaWithinWindow() {
        // #59 follow-up: the real leak pair reaches the retroactive path with
        // timeDelta = them.ts − you.ts = −1.0. The strict branch accepts
        // ±shortTextWindow; beyond it still rejects.
        let short = TextSimilarity.normalizedText("Orders.")
        XCTAssertTrue(AcousticEchoFilter.matches(normalizedYou: short, normalizedThem: short, timeDelta: -1.0))
        XCTAssertTrue(AcousticEchoFilter.matches(normalizedYou: short, normalizedThem: short, timeDelta: -2.0))
        XCTAssertFalse(AcousticEchoFilter.matches(normalizedYou: short, normalizedThem: short, timeDelta: -2.5))
    }

    func testMatchesMixedLengthPairNeverMatches() {
        // One side eligible, one sub-threshold: neither branch can claim it —
        // Jaccard needs both eligible, strict equality needs equal texts.
        let long = TextSimilarity.normalizedText("Нам нужен этот бандал для имплементации клиента")
        let short = TextSimilarity.normalizedText("Да")
        XCTAssertFalse(AcousticEchoFilter.matches(normalizedYou: short, normalizedThem: long, timeDelta: 1.0))
        XCTAssertFalse(AcousticEchoFilter.matches(normalizedYou: long, normalizedThem: short, timeDelta: 1.0))
    }
}
