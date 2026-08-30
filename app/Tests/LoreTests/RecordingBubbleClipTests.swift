import AppKit
import XCTest
@testable import LoreKit

/// The paperclip's two boxes (#203). The glyph is a switch, and its hit and
/// hover area was the bare glyph — 16×18 pt, a click the pointer had to aim at.
/// The target grows; nothing beside it may move, because the row lays the
/// paperclip out at the glyph's own box and the badge hangs off that box.
final class RecordingBubbleClipTests: XCTestCase {

    /// The symbol measured at its own point size, which is what the mask, the
    /// slash and the badge are all built against — asked for, never assumed.
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

    /// The badge is an overlay on the switch, aligned to its top-trailing
    /// corner, so it moves with any box the switch reports to the row. It
    /// reports the glyph's box — the margin is given straight back in negative
    /// padding — which is why these two numbers are the ones 0603fd6 drew and
    /// have to stay them.
    func testTheBadgeHangsWhereItAlwaysDidAndTheTargetDoesNotMoveIt() {
        XCTAssertEqual(DictationIndicatorView.badgeOffset.width, 5.5, accuracy: 0.0001)
        XCTAssertEqual(DictationIndicatorView.badgeOffset.height, -4.5, accuracy: 0.0001)
    }

    // MARK: - The badge is part of the switch (#212)

    /// The count hangs off the target's top-right corner, and a click on it used
    /// to land on nothing at all. What the pointer answers is the two rects as
    /// one.
    ///
    /// Read as geometry rather than as a click: this rect is what `clipSwitch`
    /// takes its `contentShape` off, and there is no seam a synthetic click can
    /// be sent through to check it any closer —
    /// `NSHostingView.hitTest` answers with the hosting view for every point
    /// inside it, interactive or not, and an offscreen hosting view publishes no
    /// accessibility children to hit-test either.
    func testTheBadgesOwnCornerIsInsideWhatThePaperclipAnswers() {
        let badge = DictationIndicatorView.badgeBox
        let glyphOnly = DictationIndicatorView.clipGlyphTarget
        let target = DictationIndicatorView.clipTarget(withBadge: true)
        // The top-right of the badge, half a point inside it — the corner the
        // owner clicked.
        let corner = CGPoint(x: badge.maxX - 0.5, y: badge.minY + 0.5)
        print(
            "[#212] the paperclip's target: \(NSStringFromRect(glyphOnly)) + badge "
            + "\(NSStringFromRect(badge)) = \(NSStringFromRect(target)); "
            + "the corner clicked \(NSStringFromPoint(corner))"
        )
        XCTAssertFalse(glyphOnly.contains(corner), "#203's target already reached the badge")
        XCTAssertTrue(target.contains(corner), "the badge's corner is still outside the switch")
        XCTAssertTrue(target.contains(badge), "the badge is not wholly inside the switch")
        XCTAssertTrue(target.contains(glyphOnly), "the glyph's own target shrank")
    }

    /// And it grew only where the badge is. Left, down and up to the glyph's own
    /// margin the target is still #203's box, so nothing beside the paperclip —
    /// the timer at 10 pt, the hairline past it — lost any ground to it.
    func testTheTargetGrewOnlyWhereTheBadgeHangs() {
        let glyphOnly = DictationIndicatorView.clipGlyphTarget
        let target = DictationIndicatorView.clipTarget(withBadge: true)
        XCTAssertEqual(target.minX, glyphOnly.minX, accuracy: 0.0001, "it grew leftward")
        XCTAssertEqual(target.maxY, glyphOnly.maxY, accuracy: 0.0001, "it grew downward")
        XCTAssertEqual(target.maxX - glyphOnly.maxX, 1.5, accuracy: 0.0001)
        XCTAssertEqual(glyphOnly.minY - target.minY, 0.5, accuracy: 0.0001)
    }

    /// And with nothing collected there is no badge out there to click, so the
    /// target is #203's 24×26 and not a point more.
    func testWithNothingCollectedTheTargetIsExactlyTheGlyphs() {
        XCTAssertEqual(
            DictationIndicatorView.clipTarget(withBadge: false),
            DictationIndicatorView.clipGlyphTarget
        )
    }
}
