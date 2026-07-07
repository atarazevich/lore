import XCTest
@testable import LoreKit

/// Elapsed transcript stamps (#63): mm:ss below one hour, h:mm:ss from
/// there, clamped at zero. Copy paths intentionally keep absolute HH:MM:SS.
final class ElapsedStampTests: XCTestCase {

    func testFormatsUnderOneHourAsPaddedMinuteSecond() {
        XCTAssertEqual(ElapsedStamp.label(0), "00:00")
        XCTAssertEqual(ElapsedStamp.label(59), "00:59")
        XCTAssertEqual(ElapsedStamp.label(61), "01:01")
        XCTAssertEqual(ElapsedStamp.label(725), "12:05")
        XCTAssertEqual(ElapsedStamp.label(3599), "59:59")
    }

    func testFormatsOneHourAndBeyondAsHourMinuteSecond() {
        XCTAssertEqual(ElapsedStamp.label(3600), "1:00:00")
        XCTAssertEqual(ElapsedStamp.label(3661), "1:01:01")
        XCTAssertEqual(ElapsedStamp.label(7325), "2:02:05")
        XCTAssertEqual(ElapsedStamp.label(10 * 3600 + 59), "10:00:59")
    }

    func testSubSecondFractionsTruncate() {
        XCTAssertEqual(ElapsedStamp.label(61.9), "01:01")
    }

    func testNegativeElapsedClampsToZero() {
        XCTAssertEqual(ElapsedStamp.label(-1), "00:00")
        XCTAssertEqual(ElapsedStamp.label(-3600), "00:00")
    }

    /// `ElapsedStamp.anchor` — the rule both renderers use: without a stored
    /// start (legacy session fixture), the anchor falls back to the first
    /// utterance's timestamp, so rows render from 00:00.
    func testAnchorMissingStartedAtFallsBackToFirstUtterance() {
        let first = Date(timeIntervalSince1970: 1_700_000_008)
        let second = first.addingTimeInterval(32)
        let records = [
            SessionRecord(speaker: .you, text: "Hello", timestamp: first),
            SessionRecord(speaker: .them, text: "Hi", timestamp: second),
        ]

        let anchor = ElapsedStamp.anchor(
            startedAt: nil,
            firstTimestamp: records.first?.timestamp
        )
        XCTAssertEqual(anchor, first)

        let labels = records.map {
            ElapsedStamp.label($0.timestamp.timeIntervalSince(anchor ?? $0.timestamp))
        }
        XCTAssertEqual(labels, ["00:00", "00:32"])
    }

    /// With a stored start, the anchor is the recording start — rows stamp
    /// their true offset even when the first words came later.
    func testAnchorPrefersStoredStart() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let utteranceAt = startedAt.addingTimeInterval(68)

        let anchor = ElapsedStamp.anchor(
            startedAt: startedAt,
            firstTimestamp: utteranceAt
        )
        XCTAssertEqual(anchor, startedAt)
        XCTAssertEqual(
            ElapsedStamp.label(utteranceAt.timeIntervalSince(anchor ?? utteranceAt)),
            "01:08"
        )
    }
}
