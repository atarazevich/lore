import AppKit
import SwiftUI
import XCTest
@testable import LoreKit

/// The bubble's promise, measured (#204): nothing that is visible at rest
/// changes its screen position — not when a letter is armed, not when something
/// is collected. The shape only grows, to the right and downward.
///
/// Read off the pixels rather than the layout, because the acceptance is
/// "identical positions", not "looks right": two renders of the same shape in
/// two states, compared over the region they must agree on.
@MainActor
final class RecordingBubbleRenderTests: XCTestCase {

    /// Three device pixels per point — enough that a half-point shift shows up
    /// as a differing pixel rather than rounding away.
    nonisolated static let scale: CGFloat = 3

    /// The row's own trailing padding: the last thing drawn in a resting bubble
    /// ends this far from its right edge.
    private static let rowPadding: CGFloat = 20

    /// The shape's own corner radius, and how far in from every edge the
    /// comparison starts.
    ///
    /// The outline is not an element. Its bottom corners round when the bubble is
    /// a row alone and run straight down when the list opens out of it, which is
    /// the shape changing rather than anything moving, and its edges antialias
    /// against a material that re-renders when the shape it fills changes size.
    /// The row's own padding is 20 pt across and 12 pt down, so every element the
    /// acceptance names is inside the inset window and none of the outline is.
    nonisolated static let bubbleCorner: CGFloat = 12

    /// How much a pixel may differ and still be the same pixel. The frosted
    /// material re-renders with one level of variation when the shape it fills
    /// changes size — measured at exactly 1, over four pixels of a two-item
    /// bubble whose canvas is 128 pt tall against a resting row of 42. That is
    /// not a position. Anything that has actually moved differs by tens or
    /// hundreds of levels: every real element edge in these renders is a glyph
    /// against a surface.
    nonisolated static let materialNoise = 2

    // MARK: - What moved

    /// Arming translate appends a `T` past the paperclip. Everything before it —
    /// the dot, the lock, the waveform, the timer, the paperclip — is the same
    /// picture, pixel for pixel.
    func testArmingALetterMovesNothingThatWasAlreadyOnScreen() throws {
        let rest = try raster(bubble())
        let armed = try raster(bubble(pendingMode: .translate))
        XCTAssertGreaterThan(armed.paintedWidth, rest.paintedWidth, "the T widens the resting shape")
        try assertIdentical(
            rest, armed, upToPoint: rest.paintedWidth - Self.rowPadding,
            what: "rest vs T armed"
        )
    }

    /// The same for `K`, which is the case a fixed `C T K S` order would have
    /// broken — see `RecordingBubbleRailTests`.
    func testArmingTheOperatorLetterMovesNothingEither() throws {
        let rest = try raster(bubble())
        let armed = try raster(bubble(operatorAddressed: true))
        XCTAssertGreaterThan(armed.paintedWidth, rest.paintedWidth, "the K widens the resting shape")
        try assertIdentical(
            rest, armed, upToPoint: rest.paintedWidth - Self.rowPadding,
            what: "rest vs K armed"
        )
    }

    /// Two items land: the paperclip brightens and takes a badge, and nothing
    /// before it moves. The badge is drawn past the glyph's own box, so the
    /// region that must agree ends where the paperclip begins.
    func testCollectingSomethingMovesNothingBeforeThePaperclip() throws {
        let rest = try raster(bubble())
        let holding = try raster(bubble(items: [chip(0), chip(1)]))
        XCTAssertEqual(
            holding.paintedWidth, rest.paintedWidth, accuracy: 0.0001,
            "the badge is an overlay — the resting row keeps its width"
        )
        // The paperclip itself brightens and takes the badge, which is drawn
        // past its box, so the region that must agree ends where it begins.
        try assertIdentical(
            rest, holding,
            upToPoint: rest.paintedWidth - Self.rowPadding - DictationIndicatorView.clipBox.width,
            what: "rest vs two items"
        )
    }

    // MARK: - Opened by the key (#205)

    /// Holding the hotkey inside a locked recording opens the bubble exactly as
    /// hover does — and, exactly as hover does, moves nothing that was already on
    /// screen. This is #204's headline in the form the acceptance names it:
    /// rest against opened, for every state the resting bubble can be in.
    func testOpeningTheBubbleMovesNothingThatWasAlreadyOnScreen() throws {
        for (name, make) in [
            ("nothing armed", { self.bubble(held: $0, railStartsVisible: $0) }),
            ("T armed", { self.bubble(pendingMode: .translate, held: $0, railStartsVisible: $0) }),
            ("K armed alone", {
                self.bubble(operatorAddressed: true, held: $0, railStartsVisible: $0)
            }),
            ("two items", {
                self.bubble(items: [self.chip(0), self.chip(1)], held: $0, railStartsVisible: $0)
            }),
        ] as [(String, (Bool) -> DictationIndicatorHost)] {
            let rest = try raster(make(false))
            let opened = try raster(make(true))
            // The window is the same window: the canvas was measured off the open
            // shape before anything opened, so both renders are the same size and
            // a pixel here is a point on screen there.
            XCTAssertEqual(opened.width, rest.width, "\(name): the canvas changed size")
            XCTAssertEqual(opened.height, rest.height, "\(name): the canvas changed size")
            XCTAssertGreaterThan(opened.paintedWidth, rest.paintedWidth, "\(name): it did not open")
            try assertIdentical(
                rest, opened, upToPoint: rest.paintedWidth - Self.rowPadding,
                what: "rest vs opened, \(name)"
            )
        }
    }

    /// And the open render really is drawing the rail. The letters fade in 120 ms
    /// behind the widening, which is a task no offscreen render runs, so without
    /// `railStartsVisible` the appended region would hold nothing but the shape's
    /// own surface and the comparison above would be measuring an empty margin.
    func testTheOpenedRenderActuallyDrawsTheRail() throws {
        let rest = try raster(bubble())
        let faded = try raster(bubble(held: true))
        let shown = try raster(bubble(held: true, railStartsVisible: true))

        // Past where the resting bubble ended is where the rail is appended.
        let appended = Int((rest.paintedWidth - Self.rowPadding) * Self.scale)
            ..< Int(shown.paintedWidth * Self.scale)
        let letters = compare(faded, shown, columns: appended, of: shown)
        print(
            "[#204] the rail's own ink: \(letters.moved) px differ between "
            + "faded-out and faded-in over \(appended.count) columns, worst delta "
            + "\(letters.worstDelta)"
        )
        XCTAssertGreaterThan(letters.moved, 0, "the rail drew nothing")
    }

    // MARK: - Rendering

    private struct Raster {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        /// The whole render, canvas included — the bubble sits in its top-leading
        /// corner and the rest is transparent margin.
        var pointWidth: CGFloat { CGFloat(width) / RecordingBubbleRenderTests.scale }

        /// Where the bubble itself ends: the last column that has anything drawn
        /// in it. The canvas past that is empty, so this is measured rather than
        /// assumed — and it is what the comparison regions are cut from.
        var paintedWidth: CGFloat { CGFloat(lastPainted(along: .horizontal) + 1) / scale }

        /// The same downward: the resting row's own depth, under which an open
        /// shape draws its list and a resting one draws nothing.
        var paintedHeight: CGFloat { CGFloat(lastPainted(along: .vertical) + 1) / scale }

        private enum Axis { case horizontal, vertical }

        private var scale: CGFloat { RecordingBubbleRenderTests.scale }

        private func lastPainted(along axis: Axis) -> Int {
            let outer = axis == .horizontal ? width : height
            let inner = axis == .horizontal ? height : width
            for a in stride(from: outer - 1, through: 0, by: -1) {
                for b in 0..<inner {
                    let x = axis == .horizontal ? a : b
                    let y = axis == .horizontal ? b : a
                    if pixels[(y * width + x) * 4 + 3] > 0 { return a }
                }
            }
            return -1
        }


        func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
    }

    private func bubble(
        pendingMode: UpgradeAction? = nil,
        operatorAddressed: Bool = false,
        items: [DictationItemChip] = [],
        held: Bool = false,
        railStartsVisible: Bool = false
    ) -> DictationIndicatorHost {
        let model = DictationIndicatorModel()
        model.state = .recording
        model.audioLevel = 0
        model.isLocked = true
        model.recordingSeconds = 73
        model.pendingMode = pendingMode
        model.operatorAddressed = operatorAddressed
        model.items = items
        model.collecting = true
        model.screenshotsEnabled = true
        model.held = held
        model.railStartsVisible = railStartsVisible
        return DictationIndicatorHost(model: model)
    }

    private func chip(_ index: Int) -> DictationItemChip {
        DictationItemChip(
            id: UUID(), kind: .text,
            preview: DictationItemChip.quoted("stack trace \(index)"),
            thumbnail: nil, seconds: 4 + index * 9, included: true
        )
    }

    private func raster(_ view: some View) throws -> Raster {
        let renderer = ImageRenderer(content: view)
        renderer.scale = Self.scale
        // No backdrop offscreen, so the material draws nothing — which is what
        // makes this a comparison of where things are, not of how they look.
        renderer.isOpaque = false
        let image = try XCTUnwrap(renderer.cgImage, "the bubble did not render")
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Raster(width: width, height: height, pixels: pixels)
    }

    private struct Comparison {
        let moved: Int
        let worstDelta: Int
        let first: (x: Int, y: Int)?
        let columns: Int
        let rows: Int
    }

    /// Every pixel of the two renders over `columns`, within the row band `of`
    /// leaves once its outline is inset — the corners round and unround as the
    /// list opens, which is the shape changing rather than anything moving.
    private func compare(_ a: Raster, _ b: Raster, columns: Range<Int>, of band: Raster) -> Comparison {
        let inset = Int(Self.bubbleCorner * Self.scale)
        let firstRow = inset
        let rows = min(
            Int((band.paintedHeight - Self.bubbleCorner) * Self.scale), min(a.height, b.height)
        )
        var moved = 0
        var worstDelta = 0
        var first: (x: Int, y: Int)?
        for y in firstRow..<rows {
            for x in columns.clamped(to: 0..<min(a.width, b.width)) {
                let (ar, ag, ab, aa) = a.pixel(x: x, y: y)
                let (br, bg, bb, ba) = b.pixel(x: x, y: y)
                let delta = max(
                    abs(Int(ar) - Int(br)), abs(Int(ag) - Int(bg)),
                    abs(Int(ab) - Int(bb)), abs(Int(aa) - Int(ba))
                )
                worstDelta = max(worstDelta, delta)
                if delta > Self.materialNoise {
                    moved += 1
                    if first == nil { first = (x, y) }
                }
            }
        }
        return Comparison(
            moved: moved, worstDelta: worstDelta, first: first,
            columns: columns.count, rows: rows - firstRow
        )
    }

    /// The two renders agree over the region they must, and the numbers are
    /// printed whatever the verdict — they are the acceptance.
    private func assertIdentical(
        _ a: Raster, _ b: Raster, upToPoint: CGFloat, what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let inset = Int(Self.bubbleCorner * Self.scale)
        let last = min(Int(upToPoint * Self.scale), min(a.width, b.width))
        XCTAssertGreaterThan(last, inset, file: file, line: line)
        let result = compare(a, b, columns: inset..<last, of: a)
        XCTAssertGreaterThan(result.rows, 0, file: file, line: line)
        print("""
            [#204] \(what): compared \(result.columns)×\(result.rows) px \
            (\(String(format: "%.1f", upToPoint)) pt of \(String(format: "%.1f", a.pointWidth)) pt) — \
            moved \(result.moved), worst channel delta anywhere in it \(result.worstDelta), \
            first at \(result.first.map { "(\($0.x), \($0.y))" } ?? "none") — \
            sizes \(a.width)×\(a.height) vs \(b.width)×\(b.height)
            """)
        XCTAssertEqual(result.moved, 0, "\(what): \(result.moved) pixels moved", file: file, line: line)
    }
}
