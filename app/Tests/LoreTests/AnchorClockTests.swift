import XCTest
@testable import LoreKit

/// #128: whole-meeting rebuild timestamps. A capture outage appends no
/// silence — the file is contiguous — so `start + frame/rate` math places
/// every post-gap utterance earlier by the outage length. AnchorClock must
/// re-anchor post-gap frames on the nearest anchor at-or-before them, and
/// reduce exactly to start-date math when anchors are absent or singular.
final class AnchorClockTests: XCTestCase {

    private let rate: Double = 48000
    private let t0 = Date(timeIntervalSince1970: 1_754_000_000)

    /// Two anchors with a 300s capture gap between them: 600s of audio
    /// written, then the tap dies for 5 minutes, then writing resumes.
    private func gappedClock() -> AnchorClock {
        let gapFrame = Int64(600 * rate)
        return AnchorClock(
            startDate: t0,
            sampleRate: rate,
            anchors: [
                .init(frame: 0, date: t0),
                .init(frame: gapFrame, date: t0.addingTimeInterval(600 + 300)),
            ]
        )
    }

    func testPreGapFrameKeepsStartDateMath() {
        let clock = gappedClock()
        // 100s into the file, before the gap — same as start-date math.
        let date = clock.date(atFrame: 100 * rate)
        XCTAssertEqual(date.timeIntervalSince(t0), 100, accuracy: 0.001)
    }

    func testPostGapFrameReanchors() {
        let clock = gappedClock()
        // 50s of audio after the gap anchor: wall clock is 600 + 300 + 50,
        // not the contiguous-file 650 the start-date math would give.
        let date = clock.date(atFrame: (600 + 50) * rate)
        XCTAssertEqual(date.timeIntervalSince(t0), 600 + 300 + 50, accuracy: 0.001)
    }

    func testFrameExactlyAtAnchorGetsAnchorDate() {
        let clock = gappedClock()
        let date = clock.date(atFrame: 600 * rate)
        XCTAssertEqual(date.timeIntervalSince(t0), 900, accuracy: 0.001)
    }

    func testNoAnchorsFallsBackToStartDateMath() {
        let clock = AnchorClock(startDate: t0, sampleRate: rate, anchors: [])
        let date = clock.date(atFrame: 650 * rate)
        XCTAssertEqual(date.timeIntervalSince(t0), 650, accuracy: 0.001)
    }

    func testSingleAnchorFallsBackToStartDateMath() {
        // Legacy batch-meta.json: one first-write anchor per track.
        let clock = AnchorClock(
            startDate: t0,
            sampleRate: rate,
            anchors: [.init(frame: 0, date: t0)]
        )
        let date = clock.date(atFrame: 650 * rate)
        XCTAssertEqual(date.timeIntervalSince(t0), 650, accuracy: 0.001)
    }

    func testUnsortedAnchorsAreSortedByFrame() {
        let gapFrame = Int64(600 * rate)
        let clock = AnchorClock(
            startDate: t0,
            sampleRate: rate,
            anchors: [
                .init(frame: gapFrame, date: t0.addingTimeInterval(900)),
                .init(frame: 0, date: t0),
            ]
        )
        let date = clock.date(atFrame: (600 + 50) * rate)
        XCTAssertEqual(date.timeIntervalSince(t0), 950, accuracy: 0.001)
    }
}
