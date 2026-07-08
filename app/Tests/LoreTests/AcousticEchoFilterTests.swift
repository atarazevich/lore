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

    // MARK: - Diagnostics: one summary per pass, never per utterance (#82)

    /// Counts `echoSuppressed` events currently in the shared ring.
    private func echoSummaryCount(_ store: DiagStore, path: DiagEvent.EchoPath) -> Int {
        store.recent(DiagStore.capacity).filter {
            if case .echoSuppressed(let p, _, _) = $0.event { return p == path }
            return false
        }.count
    }

    /// Ring flooding: a batch pass that suppresses many utterances must leave exactly
    /// ONE event behind. Per-utterance events would evict the launch/permission history
    /// the ring exists to keep.
    func testBatchSuppressionEmitsOneSummaryRegardlessOfCount() {
        let store = DiagStore.shared
        let before = echoSummaryCount(store, path: .batch)

        let base = Date()
        var mic: [SessionRecord] = []
        var sys: [SessionRecord] = []
        for i in 0..<25 {
            let text = "this is echoed utterance number \(i) with plenty of words"
            sys.append(SessionRecord(speaker: .them, text: text, timestamp: base.addingTimeInterval(Double(i))))
            mic.append(SessionRecord(speaker: .you, text: text, timestamp: base.addingTimeInterval(Double(i) + 0.5)))
        }

        AcousticEchoFilter.suppress(micRecords: &mic, against: sys)

        XCTAssertTrue(mic.isEmpty, "all 25 mic records were echoes")
        XCTAssertEqual(
            echoSummaryCount(store, path: .batch) - before, 1,
            "25 suppressed utterances must produce exactly one summary event"
        )
    }

    /// A pass that suppresses nothing records nothing.
    func testBatchSuppressionEmitsNoEventWhenNothingSuppressed() {
        let store = DiagStore.shared
        let before = echoSummaryCount(store, path: .batch)

        var mic = [SessionRecord(speaker: .you, text: "completely different words here entirely", timestamp: Date())]
        let sys = [SessionRecord(speaker: .them, text: "nothing alike in this sentence at all", timestamp: Date())]
        AcousticEchoFilter.suppress(micRecords: &mic, against: sys)

        XCTAssertEqual(mic.count, 1)
        XCTAssertEqual(echoSummaryCount(store, path: .batch) - before, 0)
    }

    // MARK: - echoScore returns the score the diagnostic needs (#82)

    /// The score is produced by the decision itself, so no caller recomputes Jaccard
    /// just to populate an event.
    func testEchoScoreReturnsJaccardForEligibleMatch() {
        let a = TextSimilarity.normalizedText("the quick brown fox jumps over the lazy dog")
        let score = AcousticEchoFilter.echoScore(normalizedYou: a, normalizedThem: a, timeDelta: 1.0)
        XCTAssertEqual(try XCTUnwrap(score), TextSimilarity.jaccard(a, a), accuracy: 1e-9)
    }

    /// Exact normalized equality is a Jaccard of 1 by definition — asserted, not recomputed.
    func testEchoScoreReturnsOneForShortStrictMatch() {
        let short = TextSimilarity.normalizedText("Orders.")
        XCTAssertEqual(try XCTUnwrap(AcousticEchoFilter.echoScore(
            normalizedYou: short, normalizedThem: short, timeDelta: 1.0
        )), 1.0, accuracy: 1e-9)
    }

    func testEchoScoreIsNilWhenNotAnEcho() {
        let you = TextSimilarity.normalizedText("completely different words here entirely")
        let them = TextSimilarity.normalizedText("nothing alike in this sentence at all")
        XCTAssertNil(AcousticEchoFilter.echoScore(normalizedYou: you, normalizedThem: them, timeDelta: 1.0))
    }

    /// `matches` stays the Bool view of the same decision.
    func testMatchesAgreesWithEchoScore() {
        let a = TextSimilarity.normalizedText("the quick brown fox jumps over the lazy dog")
        let b = TextSimilarity.normalizedText("nothing alike in this sentence at all")
        XCTAssertTrue(AcousticEchoFilter.matches(normalizedYou: a, normalizedThem: a, timeDelta: 1.0))
        XCTAssertFalse(AcousticEchoFilter.matches(normalizedYou: a, normalizedThem: b, timeDelta: 1.0))
    }

}
