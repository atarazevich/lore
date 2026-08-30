import AppKit
import XCTest
@testable import LoreKit

/// #211: the paste moment. The words go first and the shape says so afterwards —
/// a green checkmark where the spinner was, which detaches and falls toward the
/// cursor while the bubble fades behind it.
///
/// What a live window judges is the feel; what a test can hold is the order (the
/// paste is posted before anything is animated), the design's own numbers, the
/// three shapes a fall can take, and the fact that the window carrying the mark
/// is a hole that goes away.
@MainActor
final class PasteCheckmarkTests: XCTestCase {

    private var storage: EphemeralDictation!

    override func setUp() async throws {
        try await super.setUp()
        storage = EphemeralDictation("PasteCheckmarkTests")
    }

    override func tearDown() async throws {
        storage.tearDown()
        storage = nil
        try await super.tearDown()
    }

    /// A dictation that reaches the paste and pastes nowhere: the stub backend
    /// hears one sentence and `deliver` answers without touching the pasteboard.
    private func dictate(
        deliver: @escaping DictationDelivery = { _ in Task { true } }
    ) -> DictationCoordinator {
        let coordinator = storage.coordinator(
            backend: StubTranscriptionBackend(), deliver: deliver
        )
        coordinator.settings = isolatedSettings(
            "PasteCheckmarkTests", defaults: storage.defaults
        )
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        speak(coordinator, samples: 20_000)
        coordinator.stopRecording()
        return coordinator
    }

    /// The gesture starts behind the microphone-permission gate, and an
    /// undetermined status would put a system prompt on the user's screen.
    private func skipWithoutMicrophone() throws {
        try XCTSkipUnless(
            MicrophonePermission.status == .authorized,
            "a dictation gesture starts behind the microphone-permission gate"
        )
    }

    // MARK: - The order (the whole of what may not regress)

    /// The paste is posted while the shape is still Transcribing. The checkmark
    /// is the *next* thing that happens, so no animation can ever stand between
    /// a finished transcription and the words landing.
    func testThePasteIsPostedBeforeTheShapeStartsLeaving() async throws {
        try skipWithoutMicrophone()
        var stateWhenPosted: DictationState?
        var textWhenPosted: String?
        var coordinator: DictationCoordinator?
        coordinator = dictate { steps in
            stateWhenPosted = coordinator?.state
            if case .text(let text) = steps.first { textWhenPosted = text }
            return Task { true }
        }
        let dictation = try XCTUnwrap(coordinator)

        let marked = await waitUntil { dictation.state == .done }
        XCTAssertTrue(marked, "the shape never reached the checkmark")
        XCTAssertEqual(textWhenPosted, "mock transcription", "the paste never happened")
        XCTAssertEqual(
            stateWhenPosted, .processing,
            "the words went after the shape had already started leaving"
        )
        XCTAssertNil(dictation.lastError, "a checkmark over a failure")
    }

    /// And the shape leaves by itself when the fall has landed — the checkmark
    /// is a goodbye, not a face parked for anyone to dismiss.
    func testTheShapeLeavesWhenTheFallHasLanded() async throws {
        try skipWithoutMicrophone()
        let coordinator = dictate()

        let marked = await waitUntil { coordinator.state == .done }
        XCTAssertTrue(marked, "the shape never reached the checkmark")
        let left = await waitUntil { coordinator.state == .idle }
        XCTAssertTrue(left, "the checkmark is still standing there")
    }

    // MARK: - The clock

    /// The board's own numbers, pinned as literals so a refactor cannot quietly
    /// retime the motion the owner judged.
    func testTheFallKeepsTheBoardsNumbers() {
        XCTAssertEqual(PasteFall.standing, .milliseconds(150))
        XCTAssertEqual(PasteFall.duration, 0.25, accuracy: 0.0001)
        XCTAssertEqual(PasteFall.shrink, 0.4, accuracy: 0.0001)
    }

    /// The bubble never blinks out mid-fade.
    ///
    /// Two clocks run this moment: the coordinator holds the shape from the
    /// instant the words go, and the fall starts from the poll tick that
    /// *noticed* they went — up to a whole tick later. The hold has to outlast
    /// the fall that starts at the latest such tick, which is the case this
    /// simulates; without `PasteFall.notice` it does not.
    func testTheShapeOutlastsAFallNoticedAFullTickLate() {
        let noticedAt = DictationIndicatorManager.pollInterval
        let fadeEnds = noticedAt + PasteFall.standing
            + .milliseconds(Int(PasteFall.duration * 1000))
        XCTAssertGreaterThanOrEqual(
            PasteFall.hold, fadeEnds,
            "the panel is hidden while the mark is still fading"
        )
    }

    // MARK: - Where the mark falls

    /// The cursor is somewhere else entirely: a window of its own carries the
    /// mark, because the bubble cannot draw outside itself.
    func testAMarkBoundForACursorElsewhereLeavesTheWindow() {
        XCTAssertEqual(
            PasteFall.resolve(
                mark: Self.mark, cursor: NSPoint(x: 400, y: 300),
                window: Self.window, reduceMotion: false
            ),
            .toCursor
        )
    }

    /// The cursor is on the bubble itself: no second window, and the travel is
    /// measured in the shape's own space, which counts downward where the
    /// screen's counts up.
    func testAMarkFallingOntoItsOwnWindowOpensNoSecondOne() {
        XCTAssertEqual(
            PasteFall.resolve(
                mark: Self.mark, cursor: NSPoint(x: 700, y: 910),
                window: Self.window, reduceMotion: false
            ),
            .inside(CGSize(width: 73, height: 11))
        )
    }

    /// Reduce Motion: the mark does not travel, and the cursor it would have
    /// travelled to stops mattering.
    func testReduceMotionRefusesTheTravelAltogether() {
        XCTAssertEqual(
            PasteFall.resolve(
                mark: Self.mark, cursor: NSPoint(x: 400, y: 300),
                window: Self.window, reduceMotion: true
            ),
            .still
        )
    }

    /// A bubble's window and the mark standing in its icon slot.
    private static let window = NSRect(x: 600, y: 900, width: 240, height: 42)
    private static let mark = NSPoint(x: 627, y: 921)

    // MARK: - The window that carries it

    /// It is a hole in the screen for a quarter second and then it is not there:
    /// non-activating, never key, taking no mouse events, on every space — and
    /// torn down behind the fall it was opened for.
    func testTheFallingMarksWindowIsAHoleAndThenIsGone() async throws {
        let fall = PasteCheckmarkFall()
        XCTAssertNil(fall.panel, "a window before there was a fall")

        fall.fly(from: NSPoint(x: 700, y: 900), to: NSPoint(x: 400, y: 300), duration: 0.05)
        let panel = try XCTUnwrap(fall.panel, "the fall opened no window")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey, "it can take the keyboard from the app underneath")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents, "it can swallow a click")
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        // Big enough for both ends, so the mark is animated inside one window
        // rather than by dragging a window across the screen — and placed there
        // rather than at whatever frame `OverlayPanel`'s autosave name held.
        XCTAssertTrue(panel.frame.contains(NSPoint(x: 700, y: 900)))
        XCTAssertTrue(panel.frame.contains(NSPoint(x: 400, y: 300)))

        let gone = await waitUntil { fall.panel == nil }
        XCTAssertTrue(gone, "the window outlived the fall it was opened for")
    }

    /// And a fall cut short — a new dictation landing on top of it — takes its
    /// window with it rather than leaving one floating.
    func testCancellingAFallTakesItsWindowDown() {
        let fall = PasteCheckmarkFall()
        fall.fly(from: NSPoint(x: 700, y: 900), to: NSPoint(x: 400, y: 300))
        XCTAssertNotNil(fall.panel)
        fall.cancel()
        XCTAssertNil(fall.panel)
    }
}
