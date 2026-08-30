import AppKit
import XCTest
@testable import LoreKit

/// Where the floating bubble's window sits while the shape inside it moves
/// (#201). The shipped panel re-centred on every width it was told about, so
/// the bubble slid left by half the growth while it sprang open to the right
/// and slid back on the way out — the dot, the lock and the timer travelled
/// although nothing about them had changed. The rule these tests pin: the
/// window's left edge is the resting shape's left edge, and only a resting
/// frame is allowed to move it.
final class RecordingBubbleFrameTests: XCTestCase {

    /// One 1920-wide screen with a menu bar, and the dictation indicator's own
    /// 8pt inset under it.
    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let visibleMaxY: CGFloat = 1055
    private let topInset: CGFloat = 8

    /// The board's two widths: 189pt at rest, 314pt widened. Measured here as
    /// whatever the content reports — the panel never computes either.
    private let restWidth: CGFloat = 189
    private let openWidth: CGFloat = 314
    private let rowHeight: CGFloat = 42

    private func frame(_ width: CGFloat, height: CGFloat? = nil, anchor: CGFloat?) -> NSRect {
        TopCenteredFrame.frame(
            size: NSSize(width: width, height: height ?? rowHeight), anchorWidth: anchor,
            screenFrame: screen, visibleMaxY: visibleMaxY, topInset: topInset
        )
    }

    /// A spring's worth of widths between the two, overshoot included — the
    /// shape passes through every one of them in a third of a second.
    private var springWidths: [CGFloat] {
        Array(stride(from: restWidth, through: openWidth, by: 7.0)) + [openWidth + 4, openWidth]
    }

    // MARK: - At rest

    /// A shape no wider than its anchor is centred, whatever the anchor is.
    func testAShapeNoWiderThanItsAnchorIsCentred() {
        // No anchor at all: the first frame of a fresh panel, and every frame
        // of the Read Aloud player, which never reports one.
        XCTAssertEqual(frame(openWidth, anchor: nil).midX, screen.midX, accuracy: 0.0001)
        // The resting bubble itself.
        let resting = frame(restWidth, anchor: restWidth)
        XCTAssertEqual(resting.midX, screen.midX, accuracy: 0.0001)
        XCTAssertEqual(resting.width, restWidth, accuracy: 0.0001)
        // A digit joins the timer, or a badge appears: the resting shape is
        // wider than it was, and a resting shape is centred.
        XCTAssertEqual(frame(restWidth + 12, anchor: restWidth + 12).midX, screen.midX, accuracy: 0.0001)
        // The recording ends and a narrow status row arrives while the anchor
        // is still the bubble's: a stale wider anchor must not hang it off to
        // one side.
        XCTAssertEqual(frame(120, anchor: restWidth).midX, screen.midX, accuracy: 0.0001)
    }

    // MARK: - The widening

    func testWideningMovesOnlyTheRightEdge() {
        let resting = frame(restWidth, anchor: restWidth)
        for width in springWidths {
            let rect = frame(width, anchor: restWidth)
            XCTAssertEqual(rect.minX, resting.minX, accuracy: 0.0001,
                           "the left edge moved at width \(width)")
            // Everything the shape gained, it gained on its right.
            XCTAssertEqual(rect.maxX - resting.maxX, width - restWidth, accuracy: 0.0001)
        }
    }

    /// The list grows downward out of the same shape, so the top edge is the
    /// one thing that never moves, at any width or height.
    func testTheTopEdgeIsFixed() {
        for width in springWidths {
            for height in [rowHeight, rowHeight + 39, rowHeight + 86] {
                let rect = frame(width, height: height, anchor: restWidth)
                XCTAssertEqual(rect.maxY, visibleMaxY - topInset, accuracy: 0.0001)
            }
        }
    }

    // MARK: - Which report moves the anchor

    func testOnlyARestingReportMovesTheAnchor() {
        var anchor: CGFloat? = nil
        // First layout of a recording: the resting bubble.
        anchor = TopCenteredFrame.restWidth(
            after: PanelContentFrame(size: CGSize(width: restWidth, height: rowHeight), atRest: true),
            previous: anchor
        )
        XCTAssertEqual(anchor, restWidth)

        // Every step of the widening, and the widened shape itself.
        for width in springWidths {
            anchor = TopCenteredFrame.restWidth(
                after: PanelContentFrame(size: CGSize(width: width, height: rowHeight), atRest: false),
                previous: anchor
            )
            XCTAssertEqual(anchor, restWidth, "width \(width) moved the anchor")
        }

        // The shape settles back, and only now does the anchor follow.
        let grown = restWidth + 12
        anchor = TopCenteredFrame.restWidth(
            after: PanelContentFrame(size: CGSize(width: grown, height: rowHeight), atRest: true),
            previous: anchor
        )
        XCTAssertEqual(anchor, grown)
    }

    /// The whole movement, as the bubble performs it: rest → widened → back.
    /// The left edge is one number from the first frame to the last.
    func testTheLeftEdgeIsOneNumberAcrossAWholeHover() {
        var anchor: CGFloat?
        var lefts: Set<CGFloat> = []
        var reports = [PanelContentFrame(size: CGSize(width: restWidth, height: rowHeight), atRest: true)]
        reports += springWidths.map {
            PanelContentFrame(size: CGSize(width: $0, height: rowHeight), atRest: false)
        }
        reports += springWidths.reversed().map {
            PanelContentFrame(size: CGSize(width: $0, height: rowHeight), atRest: false)
        }
        reports.append(PanelContentFrame(size: CGSize(width: restWidth, height: rowHeight), atRest: true))

        for report in reports {
            anchor = TopCenteredFrame.restWidth(after: report, previous: anchor)
            lefts.insert(
                TopCenteredFrame.frame(
                    size: report.size, anchorWidth: anchor,
                    screenFrame: screen, visibleMaxY: visibleMaxY, topInset: topInset
                ).minX
            )
        }
        XCTAssertEqual(lefts.count, 1, "the bubble's left edge took \(lefts.count) values: \(lefts)")
    }
}
