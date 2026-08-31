import XCTest
@testable import LoreKit

/// #211, retimed by #218: the paste moment. The words go first and the shape
/// says so afterwards — a green checkmark where the spinner was, which bursts
/// where it stands while the bubble closes with it.
///
/// What a live window judges is the feel; what a test can hold is the order (the
/// paste is posted before anything is animated), the design's own numbers, and
/// the bond between the two clocks that run this moment. The fall's own tests —
/// the three shapes it could take and the transient window that carried it —
/// went with the fall: there is no second window left to test, which is the
/// whole of what #218 asked for.
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

    /// And the shape leaves by itself once the burst is over — the checkmark
    /// is a goodbye, not a face parked for anyone to dismiss.
    func testTheShapeLeavesWhenTheBurstIsOver() async throws {
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
    func testTheMarkKeepsTheBoardsNumbers() {
        XCTAssertEqual(PasteMark.standing, .milliseconds(150))
        XCTAssertEqual(PasteMark.burst, 0.2, accuracy: 0.0001)
        XCTAssertEqual(PasteMark.grow, 1.6, accuracy: 0.0001)
    }

    /// The bubble never blinks out mid-burst.
    ///
    /// Two clocks run this moment: the coordinator holds the shape from the
    /// instant the words go, and the mark starts standing from the poll tick
    /// that *noticed* they went — up to a whole tick later. The hold has to
    /// outlast the burst that starts at the latest such tick, which is the case
    /// this simulates; without `PasteMark.notice` it does not.
    func testTheShapeOutlastsABurstNoticedAFullTickLate() {
        let noticedAt = DictationIndicatorManager.pollInterval
        let burstEnds = noticedAt + PasteMark.standing
            + .milliseconds(Int(PasteMark.burst * 1000))
        XCTAssertGreaterThanOrEqual(
            PasteMark.hold, burstEnds,
            "the panel is hidden while the mark is still bursting"
        )
    }
}
