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
}
