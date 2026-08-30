import AppKit
import SwiftUI
import XCTest
@testable import LoreKit

/// Where the floating bubble's window sits while the shape inside it grows
/// (#204).
///
/// The shipped panel followed the content: it re-centred on every width it was
/// told about (#201), and then kept the resting shape's left edge as an anchor
/// re-derived from "at rest" reports (3900a37). Both moved the shape under a
/// pointer reaching for it. The window now takes one input — a canvas the shape
/// measured from its own open form before the pointer arrived — and that canvas
/// is not a function of hover, so neither is the frame.
///
/// What the view *tells* the window is pinned by `RecordingBubbleRenderTests`;
/// these are the arithmetic the window does with it.
final class RecordingBubbleFrameTests: XCTestCase {

    /// One 1920-wide screen with a menu bar, and the dictation indicator's own
    /// 8pt inset under it.
    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let visibleMaxY: CGFloat = 1055
    private let topInset: CGFloat = 8

    /// The board's two widths: 189pt at rest, 314pt widened. The canvas is the
    /// widened one, tall enough for the row and a two-item list under it.
    private let restingWidth: CGFloat = 189
    private let openWidth: CGFloat = 314
    private let rowHeight: CGFloat = 42
    private let openHeight: CGFloat = 128

    private func frame(_ canvas: BubbleCanvas) -> NSRect {
        TopCenteredFrame.frame(
            size: NSSize(width: canvas.size.width, height: canvas.size.height),
            anchorWidth: canvas.restingWidth,
            screenFrame: screen, visibleMaxY: visibleMaxY, topInset: topInset
        )
    }

    private func canvas(
        width: CGFloat? = nil, height: CGFloat? = nil, resting: CGFloat? = nil
    ) -> BubbleCanvas {
        BubbleCanvas(
            size: CGSize(width: width ?? openWidth, height: height ?? openHeight),
            restingWidth: resting ?? restingWidth
        )
    }

    // MARK: - The frame a hover cannot move

    /// The canvas is measured once per recording, from the open shape, so every
    /// width the shape springs through on the way there is a width the window is
    /// never told about. Logged, because "the window frame before and after a
    /// hover is identical" is the acceptance and the two numbers are what make a
    /// run of it readable.
    func testTheWindowIsOneFrameAcrossAWholeHover() {
        let atRest = frame(canvas())
        // The shape springs 189 → 314 and back, opens its list and closes it.
        // None of it reaches the window: the canvas already held all of it.
        let springWidths = Array(stride(from: restingWidth, through: openWidth, by: 7.0))
            + [openWidth + 4, openWidth]
        var frames: Set<NSRect> = [atRest]
        for width in springWidths + springWidths.reversed() {
            XCTAssertLessThanOrEqual(width, openWidth + 4)
            frames.insert(frame(canvas()))
        }
        let opened = frame(canvas())
        print("[#204] window before hover: \(NSStringFromRect(atRest))")
        print("[#204] window after hover:  \(NSStringFromRect(opened))")
        XCTAssertEqual(atRest, opened)
        XCTAssertEqual(frames.count, 1, "the window took \(frames.count) frames: \(frames)")
    }

    // MARK: - Where the canvas sits

    /// What the user sees at rest is centred on screen, and every point of slack
    /// the canvas carries lies to its right — which is the direction the rail
    /// and the gear grow in.
    func testTheRestingRowIsCentredAndTheSlackIsAllOnItsRight() {
        let rect = frame(canvas())
        XCTAssertEqual(rect.minX + restingWidth / 2, screen.midX, accuracy: 0.0001)
        XCTAssertEqual(rect.width, openWidth, accuracy: 0.0001)
        XCTAssertEqual(
            rect.maxX - (rect.minX + restingWidth), openWidth - restingWidth, accuracy: 0.0001
        )
    }

    /// The list grows downward inside the canvas, so the top edge is one number
    /// for every canvas the shape can ask for.
    func testTheTopEdgeIsFixedWhateverTheCanvasHolds() {
        for height in [rowHeight, rowHeight + 39, openHeight, openHeight + 86] {
            let rect = frame(canvas(height: height))
            XCTAssertEqual(rect.maxY, visibleMaxY - topInset, accuracy: 0.0001)
            XCTAssertEqual(rect.height, height, accuracy: 0.0001)
        }
    }

    /// The recording's first resting width is the anchor for the whole of it, so
    /// everything that happens later grows from the top-left corner: an item
    /// arriving, the timer reaching an hour, a letter armed by click. Centring
    /// the grown row instead would move the dot, the lock and the timer, which
    /// had not changed at all — the very thing this is here to prevent.
    func testEverythingAfterTheFirstCanvasGrowsFromTheTopLeftCorner() {
        let anchor = restingWidth
        let first = frame(canvas())
        for later in [
            canvas(width: openWidth + 22, resting: restingWidth + 16),   // a letter armed
            canvas(height: openHeight + 39, resting: restingWidth),      // one more item
            canvas(width: openWidth + 8, resting: restingWidth + 8),     // the badge arrives
            canvas(resting: restingWidth + 24),                          // the timer at the hour
        ] {
            // The anchor is the one the recording started with, not the one this
            // canvas carries — that is what `TopCenteredPanel` latches.
            let rect = TopCenteredFrame.frame(
                size: NSSize(width: later.size.width, height: later.size.height),
                anchorWidth: anchor,
                screenFrame: screen, visibleMaxY: visibleMaxY, topInset: topInset
            )
            XCTAssertEqual(rect.minX, first.minX, accuracy: 0.0001, "the left edge moved")
            XCTAssertEqual(rect.maxY, first.maxY, accuracy: 0.0001, "the top edge moved")
        }
    }

    // MARK: - Everything that is not a recording bubble

    /// Processing, done, the upgrade panel, an error, the Read Aloud player: no
    /// canvas, so the window fits the content and centres it on itself.
    func testContentWithoutACanvasIsCentredOnItself() {
        for width in [120.0, 240.0, 420.0] as [CGFloat] {
            let rect = TopCenteredFrame.frame(
                size: NSSize(width: width, height: 44), anchorWidth: nil,
                screenFrame: screen, visibleMaxY: visibleMaxY, topInset: topInset
            )
            XCTAssertEqual(rect.midX, screen.midX, accuracy: 0.0001)
            XCTAssertEqual(rect.maxY, visibleMaxY - topInset, accuracy: 0.0001)
        }
    }

    /// A resting width wider than the window it anchors is not a thing the
    /// bubble reports, but the arithmetic must not hang the window off to one
    /// side if it ever is.
    func testAnAnchorWiderThanTheWindowFallsBackToCentringIt() {
        let rect = TopCenteredFrame.frame(
            size: NSSize(width: 120, height: 44), anchorWidth: 400,
            screenFrame: screen, visibleMaxY: visibleMaxY, topInset: topInset
        )
        XCTAssertEqual(rect.midX, screen.midX, accuracy: 0.0001)
    }

    // MARK: - Where the user puts it (#213)

    /// The whole visible frame of that screen, menu bar taken off the top.
    private var visibleFrame: NSRect {
        NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: visibleMaxY)
    }

    /// The corner the bubble was dragged to is the corner everything after it
    /// grows from — the list opening, the timer reaching an hour, the next
    /// canvas of the next recording. Top-left, because that is the corner #204
    /// already pins: an origin kept as AppKit's bottom-left would push the whole
    /// shape up the screen every time the list opened.
    func testADraggedBubbleGrowsFromTheCornerItWasLeftAt() {
        let corner = NSPoint(x: 700, y: 900)
        for height in [rowHeight, openHeight, openHeight + 86] {
            let rect = TopCenteredFrame.draggedFrame(
                topLeft: corner, size: NSSize(width: openWidth, height: height),
                visibleFrame: visibleFrame
            )
            print("[#213] dragged to \(NSStringFromPoint(corner)) → \(NSStringFromRect(rect))")
            XCTAssertEqual(rect.minX, corner.x, accuracy: 0.0001, "the left edge moved")
            XCTAssertEqual(rect.maxY, corner.y, accuracy: 0.0001, "the top edge moved")
            XCTAssertEqual(rect.height, height, accuracy: 0.0001)
        }
    }

    /// Dragged at an edge, the shape is pushed back inside rather than followed
    /// off the screen.
    func testADraggedBubbleIsPushedBackInsideTheVisibleFrame() {
        let size = NSSize(width: openWidth, height: openHeight)
        for (corner, expected) in [
            (NSPoint(x: -400, y: 900), NSPoint(x: visibleFrame.minX, y: 900)),
            (NSPoint(x: 3000, y: 900), NSPoint(x: visibleFrame.maxX - openWidth, y: 900)),
            (NSPoint(x: 700, y: 4000), NSPoint(x: 700, y: visibleFrame.maxY)),
            (NSPoint(x: 700, y: -50), NSPoint(x: 700, y: visibleFrame.minY + openHeight)),
        ] {
            let rect = TopCenteredFrame.draggedFrame(
                topLeft: corner, size: size, visibleFrame: visibleFrame
            )
            XCTAssertEqual(rect.minX, expected.x, accuracy: 0.0001, "\(corner)")
            XCTAssertEqual(rect.maxY, expected.y, accuracy: 0.0001, "\(corner)")
            XCTAssertTrue(visibleFrame.contains(rect), "\(corner) left the screen: \(rect)")
        }
    }

    /// A window with no room to be pushed into — one taller than the screen it
    /// is on — keeps its top-left corner on screen instead of hanging off both
    /// ends at once.
    func testAWindowTallerThanTheScreenKeepsItsTopLeftCorner() {
        let rect = TopCenteredFrame.draggedFrame(
            topLeft: NSPoint(x: 40, y: 900),
            size: NSSize(width: openWidth, height: visibleFrame.height + 200),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(rect.minX, 40, accuracy: 0.0001)
        XCTAssertEqual(rect.maxY, visibleFrame.maxY, accuracy: 0.0001)
    }

    /// And the window itself keeps it: a canvas report is not a reason to
    /// re-centre a bubble the user has placed, and neither is the end of the
    /// recording it was placed during. The next one opens where the last one was
    /// left — until the app quits, which is the only thing that forgets.
    @MainActor
    func testADraggedOriginSurvivesACanvasReportAndTheNextRecording() throws {
        let panel = try XCTUnwrap(
            TopCenteredPanel(content: Color.clear.frame(width: 200, height: 40), topInset: 8),
            "no screen to place a panel on"
        )
        panel.setCanvas(canvas())
        XCTAssertGreaterThan(panel.lastFrame.width, 0, "the panel never placed itself")
        // The frame the panel decided, which is the one a drag takes hold of.
        let start = panel.lastFrame

        // 40 pt right and 30 pt down, in two events. The first takes hold where
        // the window already is, so the shape does not jump the recognition
        // threshold's worth of distance the instant the drag is recognised.
        panel.drag(to: NSPoint(x: start.minX + 12, y: start.maxY - 9))
        XCTAssertEqual(panel.lastFrame, start, "taking hold moved the window")
        panel.drag(to: NSPoint(x: start.minX + 52, y: start.maxY - 39))
        panel.endDrag()
        let dragged = panel.lastFrame
        print("[#213] centred \(NSStringFromRect(start)) → dragged \(NSStringFromRect(dragged))")
        XCTAssertEqual(dragged.minX, start.minX + 40, accuracy: 0.0001)
        XCTAssertEqual(dragged.maxY, start.maxY - 30, accuracy: 0.0001)

        // The 50 ms poll re-applies the same canvas twenty times a second.
        panel.setCanvas(canvas())
        XCTAssertEqual(panel.lastFrame, dragged, "the poll re-centred it")

        // The list opens: downward from the corner it was left at.
        panel.setCanvas(canvas(height: openHeight + 86))
        XCTAssertEqual(panel.lastFrame.minX, dragged.minX, accuracy: 0.0001)
        XCTAssertEqual(panel.lastFrame.maxY, dragged.maxY, accuracy: 0.0001)

        // The recording ends — processing, done, the upgrade panel — and the
        // next one starts.
        panel.setCanvas(nil)
        XCTAssertEqual(panel.lastFrame.minX, dragged.minX, accuracy: 0.0001)
        XCTAssertEqual(panel.lastFrame.maxY, dragged.maxY, accuracy: 0.0001)
        panel.setCanvas(canvas())
        XCTAssertEqual(panel.lastFrame, dragged, "the next recording went back to the middle")
    }
}
