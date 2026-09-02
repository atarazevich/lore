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

    /// Two items land: the paperclip brightens and the count appears beside it,
    /// and nothing before it moves. The count is a sibling now (#209, B2), so
    /// the row grows to the right by its own width — the region that must agree
    /// still ends where the paperclip begins.
    func testCollectingSomethingMovesNothingBeforeThePaperclip() throws {
        let rest = try raster(bubble())
        let holding = try raster(bubble(items: [chip(0), chip(1)]))
        let grew = holding.paintedWidth - rest.paintedWidth
        print(
            "[#209] two items: the row grew \(String(format: "%.2f", grew)) pt for the count, "
            + "\(DictationIndicatorView.glyphGap) pt of gap and "
            + "\(DictationIndicatorView.countDigitWidth) pt of figure"
        )
        XCTAssertEqual(
            grew,
            DictationIndicatorView.glyphGap + DictationIndicatorView.countDigitWidth,
            accuracy: 1,
            "the count is one figure past a 6 pt gap"
        )
        // The paperclip itself brightens, so the region that must agree ends
        // where it begins.
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
            ("nothing armed", { self.bubble(held: $0, railShown: $0) }),
            ("T armed", { self.bubble(pendingMode: .translate, held: $0, railShown: $0) }),
            ("K armed alone", {
                self.bubble(operatorAddressed: true, held: $0, railShown: $0)
            }),
            ("two items", {
                self.bubble(items: [self.chip(0), self.chip(1)], held: $0, railShown: $0)
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
    /// the preview's `railVisible` the appended region would hold nothing but the shape's
    /// own surface and the comparison above would be measuring an empty margin.
    func testTheOpenedRenderActuallyDrawsTheRail() throws {
        let rest = try raster(bubble())
        let faded = try raster(bubble(held: true))
        let shown = try raster(bubble(held: true, railShown: true))

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

    // MARK: - Paused by the talk key and Space (#206, #233)

    /// The window is the same window when the chord pauses. The paused row is
    /// wider — a 15 pt pause glyph where the 8 pt dot was, and `Cancel` past a
    /// hairline — and the canvas already held all of it, because the probes lay
    /// the paused row out beside the live one whether this recording is paused
    /// or not. #204's invariant, on the face #206 adds.
    func testPausingDoesNotResizeTheWindow() throws {
        let live = try raster(bubble())
        let paused = try raster(bubble(paused: true))
        print(
            "[#206] canvas live \(live.pointWidth)×\(live.pointHeight) pt, paused "
            + "\(paused.pointWidth)×\(paused.pointHeight) pt; the shape itself "
            + "\(String(format: "%.2f", live.paintedWidth)) → "
            + "\(String(format: "%.2f", paused.paintedWidth)) pt"
        )
        XCTAssertEqual(paused.width, live.width, "the canvas widened for the paused row")
        XCTAssertEqual(paused.height, live.height, "the canvas grew taller for the paused row")
        XCTAssertGreaterThan(
            paused.paintedWidth, live.paintedWidth, "the paused row drew no Cancel"
        )
    }

    /// And the paused row is still one board row tall: a keycap in the row does
    /// not decide the height any more than a spinner or a sentence does.
    func testThePausedRowIsStillOneBoardRowTall() throws {
        let paused = try raster(bubble(paused: true))
        print("[#206] the paused row is \(String(format: "%.2f", paused.paintedHeight)) pt tall")
        XCTAssertEqual(paused.paintedHeight, Self.boardRowHeight, accuracy: 0.5)
    }

    /// Opening a paused bubble appends the rail to the right of `Cancel` and
    /// moves nothing that was already on the paused row — the same promise the
    /// live bubble makes, measured the same way.
    func testOpeningAPausedBubbleMovesNothingThatWasAlreadyOnScreen() throws {
        for (name, make) in [
            ("nothing armed", { self.bubble(paused: true, held: $0, railShown: $0) }),
            ("T armed", {
                self.bubble(pendingMode: .translate, paused: true, held: $0, railShown: $0)
            }),
            ("two items", {
                self.bubble(
                    items: [self.chip(0), self.chip(1)], paused: true, held: $0, railShown: $0
                )
            }),
        ] as [(String, (Bool) -> DictationIndicatorHost)] {
            let rest = try raster(make(false))
            let opened = try raster(make(true))
            XCTAssertEqual(opened.width, rest.width, "\(name): the canvas changed size")
            XCTAssertEqual(opened.height, rest.height, "\(name): the canvas changed size")
            XCTAssertGreaterThan(opened.paintedWidth, rest.paintedWidth, "\(name): it did not open")
            try assertIdentical(
                rest, opened, upToPoint: rest.paintedWidth - Self.rowPadding,
                what: "paused at rest vs opened, \(name)"
            )
        }
    }

    /// The dot's slot really did change hands: the first run of ink in the row is
    /// a different picture, and the amber pause glyph is what is standing there.
    func testThePauseGlyphStandsWhereTheDotDid() throws {
        let live = try raster(bubble())
        let paused = try raster(bubble(paused: true))
        let slot = Int(Self.bubbleCorner * Self.scale)..<Int(24 * Self.scale)
        let changed = compare(live, paused, columns: slot, of: live)
        print(
            "[#206] the dot's slot: \(changed.moved) px differ over "
            + "\(changed.columns)×\(changed.rows), worst delta \(changed.worstDelta)"
        )
        XCTAssertGreaterThan(changed.moved, 0, "the dot is still the dot while paused")
    }

    /// The board's copy table is the contract, so every string the paused and
    /// leaving faces carry is pinned byte for byte — em dash included. Esc
    /// cancels now (#233), the way back from a pause is the chord that made it,
    /// and the pill is the pointer form of Esc under Esc's own name.
    func testThePausedFaceCarriesTheBoardsWords() {
        // The dot's own line is the mirror of the paused one (#230): the same
        // slot, the same shape of sentence, the other half of the key.
        XCTAssertEqual(DictationIndicatorView.recordingHelp, "Recording \u{2014} Esc to cancel")
        XCTAssertEqual(
            DictationIndicatorView.pausedHelp(talkKey: HotkeyKey.fn.shortName),
            "Paused \u{2014} Fn+Space to resume"
        )
        XCTAssertEqual(DictationIndicatorView.cancelLabel, "Cancel")
        XCTAssertEqual(DictationIndicatorView.cancelHelp, "Saved to history, nothing pasted")
        XCTAssertEqual(DictationIndicatorView.cancelledLine, "Cancelled \u{2014} in history")
        // The rail's Space cap: one label at a time, whichever is true, and the
        // chord spelled out in the line under it. Both come off the same table
        // the key itself reads, so the cap cannot name what Space does not do.
        let fn = HotkeyKey.fn.shortName
        XCTAssertEqual(
            HotkeyManager.SpaceAction.allCases.compactMap { $0.cap(talkKey: fn)?.label },
            ["Lock", "Pause", "Resume"]
        )
        XCTAssertEqual(
            HotkeyManager.SpaceAction.lock.cap(talkKey: fn)?.help,
            "Space locks recording, hands free"
        )
        XCTAssertEqual(
            HotkeyManager.SpaceAction.pause.cap(talkKey: fn)?.help, "Fn+Space pauses recording"
        )
        XCTAssertEqual(
            HotkeyManager.SpaceAction.resume.cap(talkKey: fn)?.help, "Fn+Space resumes recording"
        )
        // The locked sentence has one source (#228): the bubble presses the
        // key, the window says the recording is locked, and neither writes the
        // key name or the verbs itself.
        XCTAssertEqual(
            DictationIndicatorView.lockedWaysOut(talkKey: fn), "Fn to paste, Esc to cancel"
        )
        XCTAssertEqual(
            "Press " + DictationIndicatorView.lockedWaysOut(talkKey: fn),
            "Press Fn to paste, Esc to cancel"
        )
    }

    // MARK: - The leaving face (#233)

    /// F8: the dot out and the one line the moment needs, and nothing else — no
    /// waveform, no timer, no clip. Measured against the recording row it
    /// replaces, which carries all three.
    func testTheCancelledFaceIsTheDotAndTheLineAndNothingElse() throws {
        let recording = try raster(bubble(items: [chip(0), chip(1)]))
        let cancelled = try raster(bubble(items: [chip(0), chip(1)], cancelled: true))
        let leaving = "\(String(format: "%.1f", cancelled.paintedWidth)) × "
            + String(format: "%.1f", cancelled.paintedHeight)
        let live = "\(String(format: "%.1f", recording.paintedWidth)) × "
            + String(format: "%.1f", recording.paintedHeight)
        print("[#233] the leaving face is \(leaving) pt, the recording row it replaces \(live) pt")
        // The recording row is the dot, the lock, the bars, the timer and the
        // clip with its count — five elements it lays out across the shape. The
        // leaving face is the dot and one sentence, so the ink past the slot is
        // one run of words and nothing that stands apart from it.
        let runs = inkRuns(cancelled, gap: 5)
        XCTAssertLessThan(
            runs.count, inkRuns(recording, gap: 5).count,
            "the leaving face is still carrying the recording row's elements"
        )
        // The board's own row, exactly as tall as everything else the shape says.
        XCTAssertEqual(cancelled.paintedHeight, Self.boardRowHeight, accuracy: 0.5)
        // And the window is the window the recording measured (#217): the face
        // is narrower than the canvas the probes laid out, and `canvas` takes
        // the wider of the two, so a cancel resizes nothing. Offscreen there is
        // no recording before this render to have measured one, so the rule is
        // read where it lives rather than off these pixels.
        let measured = CGSize(width: recording.pointWidth, height: recording.pointHeight)
        let held = DictationIndicatorView.canvas(
            state: .done, measured: measured, restingWidth: recording.paintedWidth,
            shape: CGSize(width: cancelled.paintedWidth, height: cancelled.paintedHeight)
        )
        XCTAssertEqual(held?.size, measured, "the leaving face resized the window")
    }

    /// The line stands where the timer did, and the dot keeps the row's own
    /// slot: the shape's last frame is the shape it has been all along.
    func testTheCancelledFaceKeepsTheRowsIconSlot() throws {
        let recording = try raster(bubble())
        let cancelled = try raster(bubble(cancelled: true))
        let dot = try XCTUnwrap(inkRuns(recording, gap: 5).first, "the row drew no dot")
        let gone = try XCTUnwrap(inkRuns(cancelled, gap: 5).first, "the leaving face drew no dot")
        let centre = { (run: Range<Int>) -> CGFloat in
            CGFloat(run.lowerBound + run.upperBound) / 2 / Self.scale
        }
        let live = String(format: "%.2f", centre(dot))
        let leaving = String(format: "%.2f", centre(gone))
        print("[#233] the slot's centre: \(live) pt while recording, \(leaving) pt on the way out")
        XCTAssertEqual(centre(gone), centre(dot), accuracy: 1, "the dot moved as it went out")
    }

    // MARK: - The rail's Space cap (#233)

    /// The cap is the last thing on the rail, so opening still appends to the
    /// right of everything already lit — #204's invariant, on #233's control.
    /// (`testOpeningTheBubbleMovesNothingThatWasAlreadyOnScreen` is the general
    /// case; this is the cap's own ink.)
    func testTheSpaceCapIsDrawnAtTheEndOfTheRail() throws {
        let closed = try raster(bubble())
        let open = try raster(bubble(held: true, railShown: true))
        let caps = HotkeyManager.SpaceAction.allCases.compactMap { $0.cap(talkKey: "Fn")?.label }
        let grew = String(format: "%.2f", open.paintedWidth - closed.paintedWidth)
        print("[#233] the rail grew \(grew) pt with the cap on it; the cap's own box is "
              + "\(DictationIndicatorView.spaceCapWidth) pt for \(caps)")
        XCTAssertGreaterThan(
            open.paintedWidth - closed.paintedWidth,
            DictationIndicatorView.spaceCapWidth,
            "the rail is not wide enough to be carrying the Space cap"
        )
    }

    /// Which of the three the cap reads: the key's own table (`spaceAction`'s,
    /// walked by `DictationPauseTests`), asked as the chord's pointer form — a
    /// click holds no key, so the cap always has one of the three to show and
    /// never the row where Space is the user's own.
    func testTheSpaceCapReadsWhatSpaceDoes() {
        let rows: [(locked: Bool, paused: Bool, action: HotkeyManager.SpaceAction)] = [
            (false, false, .lock), (true, false, .pause), (true, true, .resume),
        ]
        for row in rows {
            let action = HotkeyManager.SpaceAction.decide(
                locked: row.locked, paused: row.paused, talkKeyHeld: true
            )
            XCTAssertEqual(action, row.action)
            XCTAssertNotNil(action.cap(talkKey: HotkeyKey.fn.shortName), "the cap has no label")
        }
    }

    /// Pausing changes the glyph in the slot and appends a hairline and the
    /// button — and not a pixel else moves (#219). The dot was 8 pt of its own
    /// where the pause glyph is 15, so everything right of it used to step
    /// sideways; the slot is one box now, and the row from the timer onward is
    /// the same picture.
    ///
    /// From the timer, not from the slot: the two glyphs differ (that is the
    /// point) and so do the bars beside them — a live waveform against the flat
    /// dim ones — but neither may move what follows, and the timer is what
    /// follows.
    func testPausingMovesNothingRightOfTheSlot() throws {
        let live = try raster(bubble())
        let paused = try raster(bubble(paused: true))
        let timer = inkRuns(live, gap: 5)[3]
        let after = compare(
            live, paused,
            columns: timer.lowerBound..<Int((live.paintedWidth - Self.rowPadding) * Self.scale),
            of: live
        )
        print("[#219] live vs paused, from the timer on: \(after.moved) px differ over "
              + "\(after.columns)×\(after.rows), worst delta \(after.worstDelta); the shape "
              + "\(String(format: "%.2f", live.paintedWidth)) → "
              + "\(String(format: "%.2f", paused.paintedWidth)) pt")
        XCTAssertEqual(after.moved, 0, "the paused row moved what was already on screen")
        // And the button is what the extra width is.
        XCTAssertGreaterThan(paused.paintedWidth, live.paintedWidth, "no button was appended")
    }

    // MARK: - Rendering


    // MARK: - The bubble's own tooltip (#207)

    /// A line past the card's 222 pt cap, so it wraps to the two rows the
    /// canvas keeps room for — the worst case that room exists to hold. It was
    /// the timer's own line until #212 shortened it; no string in the copy table
    /// reaches the cap any more, which is exactly why the ceiling is tested with
    /// one that does.
    private static let wrappingTip = "Dictate as long as you like. Audio is saved as you speak."

    /// The longest line the copy table actually carries, and the shortest.
    private static let longestRealTip = "Screenshot into the prompt (Fn+S)"
    private static let shortestRealTip = "Settings"

    /// A tooltip appears under the shape and the resting row is the same
    /// picture, pixel for pixel: the canvas kept the room for it before the
    /// pointer ever arrived, so the window does not resize and nothing inside
    /// it moves (#204's invariant, on #207's surface).
    func testATooltipMovesNothingInTheRestingRow() throws {
        let rest = try raster(bubble())
        let tipped = try raster(bubble(tip: Self.wrappingTip))
        XCTAssertEqual(tipped.width, rest.width, "the canvas widened for a tooltip")
        XCTAssertEqual(tipped.height, rest.height, "the canvas grew taller for a tooltip")
        // `assertIdentical` bounds the compared rows by the resting render's own
        // painted height, so the region is the resting row and nothing below it.
        try assertIdentical(
            rest, tipped, upToPoint: rest.paintedWidth - Self.rowPadding, what: "rest vs tooltip"
        )
    }

    /// And the tooltip really is drawn: ink under the shape, inside the room the
    /// canvas reserved rather than up against its edge — a card cut off at the
    /// bottom would still have passed the comparison above.
    func testTheTooltipIsDrawnInsideTheRoomTheCanvasKept() throws {
        let rest = try raster(bubble())
        let tipped = try raster(bubble(tip: Self.wrappingTip))
        print(
            "[#207] tooltip ink: resting shape ends at \(rest.paintedHeight) pt, "
            + "the tooltip's last row is \(tipped.paintedHeight) pt of a "
            + "\(tipped.pointHeight) pt canvas"
        )
        XCTAssertGreaterThan(
            tipped.paintedHeight, rest.paintedHeight + BubbleTipCard.gap,
            "nothing was drawn under the shape"
        )
        XCTAssertLessThan(
            tipped.paintedHeight, tipped.pointHeight,
            "the card runs to the canvas's last row — it is being cut off"
        )
    }

    // MARK: - An item arrives (#210)

    /// The paperclip bounces and the count rolls; nothing else in the row moves.
    /// The bounce is a transform on a glyph whose layout box is fixed, so the
    /// comparison is the whole shape *minus* that box and the 4 pt of margin
    /// around it — everything before the paperclip and everything after it, the
    /// list included. Drawn at a scale past anything the effect reaches, so what
    /// holds here holds for the effect.
    ///
    /// Both at rest and open: the trigger is a change in `items`, which the
    /// shape watches whatever width it is at.
    func testAnArrivalBouncesTheGlyphAndMovesNothingElse() throws {
        // The glyph's box in the closed row — the paperclip is the last thing in
        // it, so its right edge is the row's own trailing padding in from the
        // shape's. The row is laid out from the left, so the same band holds when
        // the shape is open and the rail follows it.
        let closed = try raster(bubble(items: [chip(0)]))
        let glyphRight = Self.glyphRight(in: closed, digits: 1)
        let band = Int((glyphRight - DictationIndicatorView.clipHitBox.width) * Self.scale)
            ..< Int((glyphRight + DictationIndicatorView.clipHitMargin) * Self.scale)

        for (name, open) in [("at rest", false), ("open", true)] {
            let rest = try raster(
                bubble(items: [chip(0)], held: open, railShown: open)
            )
            let bouncing = try raster(
                bubble(items: [chip(0)], held: open, railShown: open, clipBounce: true)
            )
            XCTAssertEqual(bouncing.width, rest.width, "\(name): the canvas changed size")
            XCTAssertEqual(
                bouncing.paintedWidth, rest.paintedWidth, accuracy: 0.0001,
                "\(name): the shape changed width"
            )
            let before = compare(
                rest, bouncing,
                columns: Int(Self.bubbleCorner * Self.scale)..<band.lowerBound, of: rest
            )
            let after = compare(
                rest, bouncing,
                columns: band.upperBound..<Int(rest.paintedWidth * Self.scale), of: rest
            )
            let glyph = compare(rest, bouncing, columns: band, of: rest)
            print(
                "[#210] \(name): rest vs mid-bounce — moved \(before.moved) px over the "
                + "\(before.columns)×\(before.rows) before the paperclip, \(after.moved) px over "
                + "the \(after.columns)×\(after.rows) after it; the glyph's own band changed "
                + "\(glyph.moved) px, worst delta \(glyph.worstDelta)"
            )
            XCTAssertEqual(before.moved, 0, "\(name): something before the paperclip moved")
            XCTAssertEqual(after.moved, 0, "\(name): something after the paperclip moved")
            XCTAssertGreaterThan(glyph.moved, 0, "\(name): the glyph did not grow at all")
        }
    }

    /// Reduce Motion drops the bounce and keeps the count. What it leaves is two
    /// still frames with different digits in them — and two still frames are
    /// exactly what an offscreen render produces, since it runs no animations at
    /// all. So this is that path, measured: the digit changes, and nothing before
    /// the paperclip does. (The bounce's *absence* cannot be rendered for the
    /// same reason its presence cannot: the preview's `clipBouncing` stands in for the
    /// one, and the pinned trigger — `reduceMotion ? 0 : arrivals` — is the
    /// whole of the other.)
    func testTheCountStillChangesWithNoAnimationAtAll() throws {
        let one = try raster(bubble(items: [chip(0)]))
        let two = try raster(bubble(items: [chip(0), chip(1)]))
        // Both counts are one figure, so the row is the same width and the only
        // band that may differ is the count's own.
        XCTAssertEqual(two.paintedWidth, one.paintedWidth, accuracy: 0.0001, "the row changed width")
        let countLeft = Self.glyphRight(in: one, digits: 1) + DictationIndicatorView.glyphGap
        let digit = compare(
            one, two,
            columns: Int(countLeft * Self.scale)..<Int(one.paintedWidth * Self.scale), of: one
        )
        print("[#210] 1 → 2 items, no animation: the count's band changed \(digit.moved) px")
        XCTAssertGreaterThan(digit.moved, 0, "the count did not change")
        try assertIdentical(
            one, two, upToPoint: countLeft, what: "1 vs 2 items, the count alone"
        )
    }

    /// Where the paperclip's own box ends, in a render whose row finishes with
    /// the clip and its count (#209, B2): back from the shape's trailing padding
    /// through the figures and the gap beside them.
    private static func glyphRight(in raster: SwiftUIRaster, digits: Int) -> CGFloat {
        raster.paintedWidth - rowPadding
            - CGFloat(digits) * DictationIndicatorView.countDigitWidth
            - DictationIndicatorView.glyphGap
    }

    // MARK: - The card is as wide as its line (#212)

    /// A short line makes a short card. The card was a fixed 222 pt whatever it
    /// held, so `Settings` was drawn on a plate two thirds empty; it now hugs
    /// its own text and only the cap can stop it.
    func testTheCardHugsAShortLineAndCapsALongOne() throws {
        let rest = try raster(bubble())
        // The line's own ink, measured here in AppKit against a card SwiftUI
        // sized — two text engines on purpose, and with a couple of points of
        // tolerance, which is what makes this a check on the layout rather than
        // a restatement of it.
        let font = NSFont.systemFont(ofSize: 11.5)
        func padded(_ line: String) -> CGFloat {
            let ink = ceil((line as NSString).size(withAttributes: [.font: font]).width)
            return min(ink + 2 * 9, BubbleTipCard.maxWidth)
        }
        var drawn: [String: CGFloat] = [:]
        for line in [Self.shortestRealTip, Self.longestRealTip, Self.wrappingTip] {
            let width = try cardWidth(of: line, under: rest.paintedHeight)
            drawn[line] = width
            print(
                "[#212] card for \"\(line)\": \(String(format: "%.2f", width)) pt drawn, "
                + "\(String(format: "%.2f", padded(line))) pt of ink and padding, "
                + "cap \(BubbleTipCard.maxWidth)"
            )
            XCTAssertLessThanOrEqual(
                width, BubbleTipCard.maxWidth + 0.5, "\(line) ran past the cap"
            )
        }
        // The two that fit on one row are that row's own width.
        for line in [Self.shortestRealTip, Self.longestRealTip] {
            XCTAssertEqual(try XCTUnwrap(drawn[line]), padded(line), accuracy: 2, "\(line)")
        }
        XCTAssertLessThan(
            try XCTUnwrap(drawn[Self.shortestRealTip]), try XCTUnwrap(drawn[Self.longestRealTip]),
            "the two cards are the same width — it is still a fixed box"
        )
        // The one past the cap breaks at it and then hugs the longer of the two
        // rows it broke into, which is wider than any card that fits on one row
        // and still inside the cap. `testOnlyTheCapPutsALineOnASecondRow` is
        // what holds the break itself.
        XCTAssertGreaterThan(
            try XCTUnwrap(drawn[Self.wrappingTip]), try XCTUnwrap(drawn[Self.longestRealTip]),
            "a line past the cap made a narrower card than one inside it"
        )
    }

    /// And a short line stays on one row: the two-row card is only ever what the
    /// cap forces. Measured as ink, because a card that wrapped for no reason
    /// would still have hugged its width.
    func testOnlyTheCapPutsALineOnASecondRow() throws {
        let rest = try raster(bubble())
        let short = try raster(bubble(tip: Self.longestRealTip))
        let wrapped = try raster(bubble(tip: Self.wrappingTip))
        let oneRow = short.paintedHeight - rest.paintedHeight
        let twoRows = wrapped.paintedHeight - rest.paintedHeight
        print(
            "[#212] card depth under the shape: \(String(format: "%.2f", oneRow)) pt for the "
            + "longest line in the copy table, \(String(format: "%.2f", twoRows)) pt for one past the cap"
        )
        // A whole row deeper, not a point deeper: capping the width without
        // passing the cap on to the text left the long line on one row, running
        // out of the plate, and a bare `<` did not notice.
        XCTAssertGreaterThan(
            twoRows - oneRow, 10, "the line past the cap was not put on a second row"
        )
    }

    /// The card's own width, read off the render. The card is the only thing
    /// drawn under the shape, and an offscreen render reports the pointer at 0,
    /// so it is pushed as far left as it goes and its last painted column is its
    /// width.
    private func cardWidth(of line: String, under shapeHeight: CGFloat) throws -> CGFloat {
        let tipped = try raster(bubble(tip: line))
        let firstRow = Int((shapeHeight + 1) * Self.scale)
        var last = -1
        var first = tipped.width
        for y in firstRow..<tipped.height {
            for x in 0..<tipped.width where tipped.pixel(x: x, y: y).3 > 0 {
                last = max(last, x)
                first = min(first, x)
            }
        }
        XCTAssertGreaterThan(last, 0, "nothing was drawn under the shape")
        XCTAssertEqual(first, 0, "the card is not against the canvas's left edge")
        return CGFloat(last + 1) / Self.scale
    }

    // MARK: - The faces after release (#209)

    /// Every face the board draws, rendered at the shape's own width. The
    /// numbers are the acceptance: one shape per face, no wider than the
    /// recording bubble opens to, one row unless the board gives the face a
    /// button of its own line.
    func testEveryFaceRendersAsOneShapeNoWiderThanTheBubble() throws {
        // The widest any face may be: the wrapped sentence's cap, the icon, the
        // 10 pt beside it and the row's own padding.
        let ceiling = DictationIndicatorView.faceWrapWidth
            + DictationIndicatorView.faceIconSide + 10 + 2 * Self.rowPadding

        var drawn: [(String, CGFloat, CGFloat)] = []
        for (name, host) in try faces() {
            let render = try raster(host)
            drawn.append((name, render.paintedWidth, render.paintedHeight))
            XCTAssertGreaterThan(render.paintedWidth, 0, "\(name): nothing was drawn")
            XCTAssertLessThanOrEqual(
                render.paintedWidth, ceiling + 0.5, "\(name): wider than the shape may be"
            )
        }
        for (name, width, height) in drawn {
            print("[#209] \(name): \(String(format: "%.1f", width)) × "
                  + "\(String(format: "%.1f", height)) pt (the board's row is "
                  + "\(Self.boardRowHeight) pt, ceiling \(ceiling) pt)")
        }

        func size(_ name: String) throws -> (width: CGFloat, height: CGFloat) {
            let found = try XCTUnwrap(drawn.first { $0.0 == name })
            return (found.1, found.2)
        }
        // Every face that fits on one line is the board's own row, exactly as
        // tall as the recording bubble it replaces — the height is one of the
        // two things a face change may not move.
        for name in ["T1 transcribing", "F3 downloading", "F5 paste failed", "F6 cleanup failed"] {
            XCTAssertEqual(
                try size(name).height, Self.boardRowHeight, accuracy: 0.5,
                "\(name): it is not the board's row"
            )
        }
        // A face whose action stands on its own line is a row taller; F5's is
        // inline (P1), which is the whole point of P1.
        for name in ["F1 mic stall", "F2 nothing came through", "F4 download failed"] {
            XCTAssertGreaterThan(
                try size(name).height, Self.boardRowHeight + 10,
                "\(name): its button is not on its own line"
            )
        }
        // The two long sentences wrap, so both are exactly the row's own cap.
        for name in ["F1 mic stall", "F4 download failed"] {
            XCTAssertEqual(
                try size(name).width, ceiling, accuracy: 0.5,
                "\(name): the wrapped sentence is not at the row's cap"
            )
        }
    }

    /// T1 keeps the clip and its count: the items are still riding along, and
    /// the person can see it. The face without them is the same row, narrower by
    /// exactly what the clip and its count take.
    func testTheTranscribingFaceKeepsTheClipAndItsCount() throws {
        let bare = try raster(face(.processing, seconds: 66))
        let carrying = try raster(face(.processing, seconds: 66, items: [chip(0), chip(1)]))
        let grew = carrying.paintedWidth - bare.paintedWidth
        print("[#209] the transcribing face grew \(String(format: "%.2f", grew)) pt for the clip "
              + "and its count (glyph \(DictationIndicatorView.clipBox.width) + gap "
              + "\(DictationIndicatorView.glyphGap) + figure "
              + "\(DictationIndicatorView.countDigitWidth) + 10 pt beside it)")
        XCTAssertEqual(
            grew,
            10 + DictationIndicatorView.clipBox.width + DictationIndicatorView.glyphGap
                + DictationIndicatorView.countDigitWidth,
            accuracy: 1,
            "the clip and its count are not in the transcribing face"
        )
        XCTAssertEqual(
            carrying.paintedHeight, bare.paintedHeight, accuracy: 0.5,
            "the clip made the row taller"
        )
    }

    /// The paste moment is the transcribing row with a green mark in the icon
    /// slot (#211, the board's frame 2). Everything else in it stands exactly
    /// where it stood: same width, same height, same ink past the slot.
    ///
    /// The spinner draws nothing offscreen — an `ImageRenderer` runs no
    /// animations — so the slot is bare in the one and inked in the other, which
    /// is precisely the difference this face is.
    func testThePasteFaceIsTheTranscribingRowWithAGreenMarkInTheSlot() throws {
        let transcribing = try raster(face(.processing, seconds: 66, items: [chip(0), chip(1)]))
        let delivered = try raster(
            face(.processing, seconds: 66, items: [chip(0), chip(1)], delivered: true)
        )
        XCTAssertEqual(
            delivered.paintedWidth, transcribing.paintedWidth, accuracy: 0.5,
            "the mark moved the row it stands in"
        )
        XCTAssertEqual(
            delivered.paintedHeight, transcribing.paintedHeight, accuracy: 0.5,
            "the mark made the row taller"
        )

        // The slot itself, and the 10 pt of gap after it the 14 pt glyph bleeds
        // into — the same bleed every failure face's `xmark.circle.fill` has.
        // Bare while the spinner is there (an `ImageRenderer` draws none), inked
        // once the mark arrives, and the mark is the design's own green.
        let slot = Int(DictationIndicatorView.rowPaddingH * Self.scale)
            ..< Int((DictationIndicatorView.rowPaddingH + DictationIndicatorView.faceIconSide + 10)
                    * Self.scale)
        let mark = compare(transcribing, delivered, columns: slot, of: delivered)
        print("[#211] the icon slot: \(mark.moved) px differ between the spinner and the "
              + "mark over \(mark.columns)×\(mark.rows), worst delta \(mark.worstDelta)")
        XCTAssertGreaterThan(mark.moved, 0, "the mark was not drawn")
        try assertGreen(delivered, columns: slot)

        // And from the label onward nothing changed at all.
        let rest = slot.upperBound..<Int(delivered.paintedWidth * Self.scale)
        let after = compare(transcribing, delivered, columns: rest, of: delivered)
        print("[#211] past the slot: \(after.moved) px differ over \(after.columns)×"
              + "\(after.rows), worst delta \(after.worstDelta)")
        XCTAssertEqual(after.moved, 0, "the mark moved the rest of the row")
    }

    /// What the paste's mark looks like and nothing else in these rows does:
    /// bright, and further from red and blue than the material's own variation
    /// could carry it (two levels there against eighty here). One predicate,
    /// because two copies of "the mark's green" in one file are two chances to
    /// disagree about it — `assertGreen` reads it in the slot, `greenCentre`
    /// across the whole render.
    private static func isMarkGreen(_ pixel: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let (r, g, b, _) = pixel
        return Int(g) > 150 && Int(g) - Int(r) > 80 && Int(g) - Int(b) > 80
    }

    /// The mark is `LoreTheme.Accent.green` and nothing near it. The brightest
    /// pixel in the slot is printed whatever the verdict — it is the number that
    /// makes a run of this readable.
    private func assertGreen(_ raster: SwiftUIRaster, columns: Range<Int>) throws {
        let rows = Int(raster.paintedHeight * Self.scale)
        var best: (r: Int, g: Int, b: Int) = (0, 0, 0)
        var found = false
        for y in 0..<rows {
            for x in columns {
                let pixel = raster.pixel(x: x, y: y)
                if Int(pixel.1) > best.g { best = (Int(pixel.0), Int(pixel.1), Int(pixel.2)) }
                if Self.isMarkGreen(pixel) { found = true }
            }
        }
        print("[#211] the mark's brightest pixel: r \(best.r) g \(best.g) b \(best.b) "
              + "(the token is 50, 215, 75)")
        XCTAssertTrue(found, "nothing in the slot is the mark's own green")
    }

    /// The mark stands exactly where the record dot stood (#217). The slot is
    /// one 15 pt box in every state the row can be in — the dot, the amber pause
    /// glyph, the spinner and the paste's mark all centre in it — so the release
    /// migrates the row rather than replacing it. Measured as the centre of the
    /// first run of ink, because the two glyphs are different sizes inside the
    /// one box (an 8 pt dot, a 14 pt mark) and it is the box they share.
    ///
    /// The spinner itself draws nothing offscreen — an `ImageRenderer` runs no
    /// animations — so the mark is the face that can be measured here.
    func testTheMarkStandsWhereTheRecordingDotStood() throws {
        let recording = try raster(bubble())
        let delivered = try raster(face(.processing, seconds: 73, delivered: true))
        // The dot is the row's first run of ink; the mark is green, which the
        // ink test — a red-channel brightness — cannot see, so it is found by
        // its own colour instead.
        let dotRun = try XCTUnwrap(inkRuns(recording, gap: 5).first, "the row drew no dot")
        let dot = CGFloat(dotRun.lowerBound + dotRun.upperBound) / 2 / Self.scale
        let mark = try greenCentre(of: delivered)
        print("[#217] the slot's centre: \(String(format: "%.2f", dot)) pt while recording, "
              + "\(String(format: "%.2f", mark)) pt once the words are away "
              + "(the row's padding \(DictationIndicatorView.rowPaddingH) pt plus half a "
              + "\(DictationIndicatorView.faceIconSide) pt slot)")
        XCTAssertEqual(mark, dot, accuracy: 1, "the slot changed hands and moved")
        XCTAssertEqual(
            dot,
            DictationIndicatorView.rowPaddingH + DictationIndicatorView.faceIconSide / 2,
            accuracy: 1,
            "the dot is not centred in the row's own icon slot"
        )
    }

    /// Where the paste's mark stands, across the render: the middle of every
    /// column carrying its green (`isMarkGreen`), which in these rows is the
    /// mark and nothing else.
    private func greenCentre(of raster: SwiftUIRaster) throws -> CGFloat {
        let rows = Int(raster.paintedHeight * Self.scale)
        var first = raster.width
        var last = -1
        for y in 0..<rows {
            for x in 0..<raster.width where Self.isMarkGreen(raster.pixel(x: x, y: y)) {
                first = min(first, x)
                last = max(last, x)
            }
        }
        XCTAssertGreaterThan(last, 0, "nothing green was drawn")
        return CGFloat(first + last + 1) / 2 / Self.scale
    }

    /// A frozen timer is a timer: the face draws the dictation's own length, and
    /// a run with no length of its own — a history retry — draws none.
    func testTheTranscribingFaceFreezesTheTimerAndDrawsNoneWithoutOne() throws {
        let timed = try raster(face(.processing, seconds: 66))
        let untimed = try raster(face(.processing, seconds: 0))
        print("[#209] transcribing at 1:06 is \(String(format: "%.1f", timed.paintedWidth)) pt, "
              + "with no length of its own \(String(format: "%.1f", untimed.paintedWidth)) pt")
        XCTAssertGreaterThan(
            timed.paintedWidth, untimed.paintedWidth + 20, "the frozen timer was not drawn"
        )
    }

    // MARK: - One baseline (#209)

    /// The label and the mono figures beside it stand on one line. Centre
    /// alignment did not give that — a proportional label's line box and a
    /// monospaced figure's do not centre alike, and the owner saw the digits
    /// sitting high beside "Transcribing".
    ///
    /// Measured off the ink: the bottom of each element's first glyph, which is
    /// a flat stroke on the baseline for `T`, `N` and every figure. Only a
    /// run's own tail can carry a descender, so the first glyph is the safe one.
    func testTheLabelAndTheMonoTimerShareABaseline() throws {
        let render = try raster(face(.processing, seconds: 66))
        let runs = inkRuns(render, gap: 5)
        // The spinner draws nothing offscreen (an `ImageRenderer` runs no
        // animations), so the runs are the label and then the timer.
        XCTAssertGreaterThanOrEqual(runs.count, 2, "the face drew fewer elements than it has")
        let label = try baseline(of: runs[runs.count - 2], in: render)
        let timer = try baseline(of: runs[runs.count - 1], in: render)
        print("[#209] transcribing: the label's baseline \(String(format: "%.2f", label)) pt, "
              + "the timer's \(String(format: "%.2f", timer)) pt, "
              + "\(runs.count) runs of ink across the row")
        XCTAssertEqual(label, timer, accuracy: 1, "the label and the timer sit on two lines")
    }

    // MARK: - The arrival says nothing (#216)

    /// A dictation that has not heard anything yet says so with the dot and the
    /// bars, never with a sentence. The row swapped the timer for "No signal
    /// from microphone" on every start and slid it back the moment a sound
    /// arrived; now the timer never leaves its place, the row is the same width
    /// either way, and everything from the timer onward is the same picture.
    func testAQuietMicrophoneMovesNothingAndSaysNothing() throws {
        let running = try raster(bubble())
        let quiet = try raster(bubble(noSignal: true))
        XCTAssertEqual(
            quiet.paintedWidth, running.paintedWidth, accuracy: 0.5,
            "the quiet row is a different width — a sentence took the timer's place"
        )
        // The timer is the fourth run of ink: the dot, the lock and the bars
        // come before it, the paperclip after.
        let timer = inkRuns(running, gap: 5)[3]
        let after = compare(
            running, quiet,
            columns: timer.lowerBound..<Int(running.paintedWidth * Self.scale), of: running
        )
        print("[#216] quiet vs speaking, from the timer on: \(after.moved) px differ over "
              + "\(after.columns)×\(after.rows), worst delta \(after.worstDelta)")
        XCTAssertEqual(after.moved, 0, "the timer, or something after it, moved")

        // And what is left of the message: the dot, dimmed in its own slot.
        let slot = Int(Self.bubbleCorner * Self.scale)..<Int(24 * Self.scale)
        let dot = compare(running, quiet, columns: slot, of: running)
        print("[#216] the dot's slot: \(dot.moved) px differ, worst delta \(dot.worstDelta)")
        XCTAssertGreaterThan(dot.moved, 0, "the dot reads the same quiet or not")
    }

    /// The list rows say what a click does, not which state they are in — the
    /// dimming and the strike-through already draw that. The spoken name keeps
    /// the state, because a screen reader has neither to read it off.
    func testTheListRowsCarryTheBoardsWords() {
        XCTAssertEqual(DictationIndicatorView.rowToggleHelp, "Click to toggle")
        XCTAssertEqual(DictationIndicatorView.rowState(included: true), "In the prompt")
        XCTAssertEqual(DictationIndicatorView.rowState(included: false), "Left out")
    }

    /// And the row is still the board's own row: switching it to a baseline
    /// alignment moved nothing and grew nothing.
    func testTheRecordingRowIsStillOneBoardRowTall() throws {
        let rest = try raster(bubble())
        print("[#209] the resting row is \(String(format: "%.2f", rest.paintedHeight)) pt tall")
        XCTAssertEqual(rest.paintedHeight, Self.boardRowHeight, accuracy: 0.5)
    }

    /// 12 pt of padding, the waveform's own 18, and 12 again — the board's row.
    private static let boardRowHeight: CGFloat = 42

    /// Every face on the board, named as the board names them.
    private func faces() throws -> [(String, DictationIndicatorHost)] {
        [
            ("T1 transcribing", face(.processing, seconds: 66, items: [chip(0), chip(1)])),
            ("F3 downloading", face(.loadingModel)),
            ("F1 mic stall", face(.done, error: .micUnavailable(
                "The AirPods Pro microphone is unavailable."
            ))),
            ("F2 nothing came through", face(.done, error: .nothingCameThrough)),
            ("F4 download failed", face(.done, error: .modelDownloadFailed)),
            ("F5 paste failed", face(.done, error: .pasteFailed)),
            ("F6 cleanup failed", face(.done, error: .cleanupFailed)),
        ]
    }

    private func face(
        _ state: DictationState, error: DictationFace? = nil,
        seconds: Int = 0, items: [DictationItemChip] = [], delivered: Bool = false
    ) -> DictationIndicatorHost {
        let model = DictationIndicatorModel()
        // The paste moment is `.done` with nothing wrong (#211) — the same row
        // the transcribing face draws, with a mark where the spinner was.
        model.state = delivered ? .done : state
        model.lastError = error
        model.recordingSeconds = seconds
        model.items = items
        model.collecting = true
        return DictationIndicatorHost(model: model)
    }

    /// What counts as a stroke rather than the surface under it. Offscreen the
    /// material fills the whole shape at full alpha, so ink is told from surface
    /// by brightness, not by coverage: the surface renders at ~48, the faintest
    /// text the row draws (the frozen timer, `--faint`) at ~108, and the
    /// brightest at ~224. Halfway between the first two.
    private static let inkLevel = 80

    /// The runs of ink across a rendered row, split wherever it leaves `gap`
    /// points or more of surface — the 10 pt the shape puts between its
    /// elements, never the point or two between the letters of one word.
    private func inkRuns(_ raster: SwiftUIRaster, gap: CGFloat) -> [Range<Int>] {
        painted(raster, minimumGap: Int(gap * Self.scale))
    }

    private func painted(_ raster: SwiftUIRaster, minimumGap: Int) -> [Range<Int>] {
        let rows = Int(raster.paintedHeight * Self.scale)
        var runs: [Range<Int>] = []
        var start: Int?
        var blank = 0
        for x in 0..<raster.width {
            let inked = (0..<rows).contains { Int(raster.pixel(x: x, y: $0).0) > Self.inkLevel }
            if inked {
                if start == nil { start = x }
                blank = 0
            } else if let began = start {
                blank += 1
                if blank >= minimumGap {
                    runs.append(began..<(x - blank + 1))
                    start = nil
                    blank = 0
                }
            }
        }
        if let began = start { runs.append(began..<raster.width) }
        return runs
    }

    /// Where a run of ink stands: the bottom of its first glyph. Sub-split at
    /// any column of bare surface, so the run's own tail — the only place a
    /// descender can be in these strings — is never what is measured.
    private func baseline(of run: Range<Int>, in raster: SwiftUIRaster) throws -> CGFloat {
        let glyph = try XCTUnwrap(
            painted(raster, minimumGap: 1).first { run.contains($0.lowerBound) }
        )
        let rows = Int(raster.paintedHeight * Self.scale)
        var last = -1
        for y in 0..<rows {
            for x in glyph where Int(raster.pixel(x: x, y: y).0) > Self.inkLevel {
                last = max(last, y)
            }
        }
        XCTAssertGreaterThan(last, 0, "the run carried no ink at all")
        return CGFloat(last + 1) / Self.scale
    }

    private func bubble(
        pendingMode: UpgradeAction? = nil,
        operatorAddressed: Bool = false,
        items: [DictationItemChip] = [],
        paused: Bool = false,
        cancelled: Bool = false,
        held: Bool = false,
        railShown: Bool = false,
        clipBounce: Bool = false,
        noSignal: Bool = false,
        tip: String? = nil
    ) -> DictationIndicatorHost {
        let model = DictationIndicatorModel()
        model.state = .recording
        model.audioLevel = 0
        model.isLocked = true
        model.recordingSeconds = 73
        model.pendingMode = pendingMode
        model.operatorAddressed = operatorAddressed
        model.items = items
        model.noSignal = noSignal
        model.collecting = true
        model.held = held
        model.paused = paused
        model.cancelled = cancelled
        model.renderPreview = BubbleRenderPreview(
            railVisible: railShown, tip: tip, clipBouncing: clipBounce
        )
        return DictationIndicatorHost(model: model)
    }

    private func chip(_ index: Int) -> DictationItemChip {
        DictationItemChip(
            id: UUID(), kind: .text,
            preview: DictationItemChip.quoted("stack trace \(index)"),
            thumbnail: nil, seconds: 4 + index * 9, included: true
        )
    }

    private func raster(_ view: some View) throws -> SwiftUIRaster {
        // No backdrop offscreen, so the material draws nothing — which is what
        // makes this a comparison of where things are, not of how they look.
        try SwiftUIRaster.render(view, scale: Self.scale, opaque: false)
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
    private func compare(_ a: SwiftUIRaster, _ b: SwiftUIRaster, columns: Range<Int>, of band: SwiftUIRaster) -> Comparison {
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
        _ a: SwiftUIRaster, _ b: SwiftUIRaster, upToPoint: CGFloat, what: String,
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
