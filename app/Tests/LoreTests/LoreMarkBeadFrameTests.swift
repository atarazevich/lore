import XCTest
@testable import LoreKit

/// Where the recording bead lands inside the status-item button.
///
/// `MenuBarController` reads `NSStatusBarButton.isFlipped` at runtime instead of
/// baking today's value in — flippedness is a probed fact, not an API guarantee —
/// so both conventions have to place the same *visible* dot. Only one of them can
/// ever run on a given macOS, which is exactly why the other needs a test.
final class LoreMarkBeadFrameTests: XCTestCase {

    /// What the menu bar actually hands us on macOS 27: a square button of the
    /// bar's own height, with the 16 x 18 drawing box centred in it.
    private let button = CGRect(x: 0, y: 0, width: 22, height: 22)

    /// Top-left of the drawing box, in top-down coordinates.
    private var boxOrigin: CGPoint {
        CGPoint(x: (button.width - LoreMarkGeometry.statusBox.width) / 2,
                y: (button.height - LoreMarkGeometry.statusBox.height) / 2)
    }

    func testFlippedMeasuresFromTheTopEdge() {
        let frame = LoreMark.beadFrame(in: button, flipped: true)
        XCTAssertEqual(frame.midX, boxOrigin.x + LoreMarkGeometry.beadCenter.x, accuracy: 0.0001)
        // A flipped view already counts +y downwards, so the generated offset
        // applies as measured.
        XCTAssertEqual(frame.midY, boxOrigin.y + LoreMarkGeometry.beadCenter.y, accuracy: 0.0001)
    }

    func testUnflippedPlacesTheSameVisiblePoint() {
        let frame = LoreMark.beadFrame(in: button, flipped: false)
        XCTAssertEqual(frame.midX, boxOrigin.x + LoreMarkGeometry.beadCenter.x, accuracy: 0.0001)
        // Bottom-left origin: the same distance below the top edge is that
        // distance subtracted from the button's height.
        XCTAssertEqual(frame.midY,
                       button.height - (boxOrigin.y + LoreMarkGeometry.beadCenter.y),
                       accuracy: 0.0001)
    }

    func testBothConventionsStraddleTheButtonAxis() {
        let flipped = LoreMark.beadFrame(in: button, flipped: true)
        let upright = LoreMark.beadFrame(in: button, flipped: false)
        XCTAssertEqual(flipped.midX, upright.midX, accuracy: 0.0001,
                       "flippedness is a y-axis convention; x must not move")
        XCTAssertEqual((flipped.midY + upright.midY) / 2, button.midY, accuracy: 0.0001,
                       "the two centres must mirror across the button's horizontal axis")
        XCTAssertEqual(flipped.size, upright.size)
    }

    /// The host is padded so `LorePulsingDot`'s size/2 glow is not clipped by its
    /// own bounds — and that padding must still fit inside the button, or the
    /// glow gets clipped by the status item instead.
    func testGlowPaddingFitsInsideTheButton() {
        for flipped in [true, false] {
            let frame = LoreMark.beadFrame(in: button, flipped: flipped)
            XCTAssertEqual(frame.width, LoreMarkGeometry.beadSize * 4, accuracy: 0.0001)
            XCTAssertEqual(frame.height, LoreMarkGeometry.beadSize * 4, accuracy: 0.0001)
            XCTAssertTrue(button.contains(frame),
                          "bead host \(frame) escapes the button (flipped: \(flipped))")
        }
    }
}
