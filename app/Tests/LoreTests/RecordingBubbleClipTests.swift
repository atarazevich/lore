import AppKit
import XCTest
@testable import LoreKit

/// The paperclip's two boxes (#203). The glyph is a switch, and its hit and
/// hover area was the bare glyph — 16×18 pt, a click the pointer had to aim at.
/// The target grows; nothing beside it may move, because the row lays the
/// paperclip out at the glyph's own box and the count stands beside that box
/// (#209, B2 — it was a badge hung off its top-right corner).
final class RecordingBubbleClipTests: XCTestCase {

    /// The symbol measured at its own point size, which is what the mask, the
    /// slash and the count's own gap are all built against — asked for, never
    /// assumed.
    func testTheGlyphBoxIsTheSymbolsOwnBoundsPlusItsSlack() {
        let box = DictationIndicatorView.clipBox
        XCTAssertEqual(box.width, 16, accuracy: 0.0001)
        XCTAssertEqual(box.height, 18, accuracy: 0.0001)
    }

    /// The board's floor is 24×24; the reach the acceptance names is 4 pt on
    /// every side.
    func testTheTargetIsTheGlyphPlusFourPointsOnEverySide() {
        let glyph = DictationIndicatorView.clipBox
        let target = DictationIndicatorView.clipHitBox
        XCTAssertEqual(DictationIndicatorView.clipHitMargin, 4, accuracy: 0.0001)
        XCTAssertEqual(target.width - glyph.width, 8, accuracy: 0.0001)
        XCTAssertEqual(target.height - glyph.height, 8, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(target.width, 24)
        XCTAssertGreaterThanOrEqual(target.height, 24)
    }

    // MARK: - The count is a sibling, not a badge (#209, B2)

    /// The ring is gone, so the switch answers for the glyph and nothing else:
    /// #203's 24×26 pt box, and no reach out over a corner where a badge used to
    /// hang (#212's union). The count stands beside the glyph now, its own
    /// element, and the switch never grew leftward, downward or up into the row
    /// to hold it.
    ///
    /// Read as geometry rather than as a click: this rect is what `clipSwitch`
    /// takes its `contentShape` off, and there is no seam a synthetic click can
    /// be sent through to check it any closer —
    /// `NSHostingView.hitTest` answers with the hosting view for every point
    /// inside it, interactive or not, and an offscreen hosting view publishes no
    /// accessibility children to hit-test either.
    func testTheSwitchAnswersForTheGlyphAndNothingBeside() {
        let glyph = DictationIndicatorView.clipBox
        let target = DictationIndicatorView.clipGlyphTarget
        print("[#209] the paperclip's target: \(NSStringFromRect(target)) around a "
              + "\(glyph.width)×\(glyph.height) glyph, count \(DictationIndicatorView.glyphGap) pt "
              + "to its right at \(DictationIndicatorView.countDigitWidth) pt a figure")
        XCTAssertEqual(target.minX, -DictationIndicatorView.clipHitMargin, accuracy: 0.0001)
        XCTAssertEqual(target.minY, -DictationIndicatorView.clipHitMargin, accuracy: 0.0001)
        XCTAssertEqual(target.maxX, glyph.width + DictationIndicatorView.clipHitMargin, accuracy: 0.0001)
        XCTAssertEqual(target.maxY, glyph.height + DictationIndicatorView.clipHitMargin, accuracy: 0.0001)
        // The count is past the target's right edge, not inside it — it is read,
        // never clicked, and the switch does not answer for it.
        let countLeft = CGPoint(
            x: glyph.width + DictationIndicatorView.glyphGap + 0.5, y: glyph.height / 2
        )
        XCTAssertFalse(target.contains(countLeft), "the switch still reaches into the count")
    }

    /// The board's own gap — the one the rail already leaves between its
    /// letters — and one figure's room beside the glyph.
    func testTheCountStandsSixPointsFromTheGlyph() {
        XCTAssertEqual(DictationIndicatorView.glyphGap, 6, accuracy: 0.0001)
        XCTAssertEqual(DictationIndicatorView.countSize, 11, accuracy: 0.0001)
        XCTAssertGreaterThan(DictationIndicatorView.countDigitWidth, 0)
    }

    // MARK: - What counts as an arrival (#210)

    /// The bounce plays for an item that was not there a moment ago — and for
    /// nothing else. A row switched off and on rewrites `items` without anything
    /// arriving, and the end of a dictation empties the list.
    func testOnlyANewItemCountsAsAnArrival() {
        let first = chip()
        let second = chip()
        let leftOut = chip(id: first.id, included: false)
        XCTAssertTrue(DictationIndicatorView.itemArrived(from: [], to: [first]))
        XCTAssertTrue(DictationIndicatorView.itemArrived(from: [first], to: [first, second]))
        XCTAssertFalse(DictationIndicatorView.itemArrived(from: [first], to: [first]))
        XCTAssertFalse(
            DictationIndicatorView.itemArrived(from: [first], to: [leftOut]),
            "a row left out of the prompt is not an arrival"
        )
        XCTAssertFalse(
            DictationIndicatorView.itemArrived(from: [first, second], to: []),
            "the dictation ending is not an arrival"
        )
    }

    private func chip(id: UUID = UUID(), included: Bool = true) -> DictationItemChip {
        DictationItemChip(
            id: id, kind: .text, preview: DictationItemChip.quoted("stack trace"),
            thumbnail: nil, seconds: 4, included: included
        )
    }

}
