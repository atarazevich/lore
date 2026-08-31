import AppKit
import XCTest
@testable import LoreKit

/// What the hotkey means inside a locked recording (#205).
///
/// It used to mean one thing: the next release stops and pastes. It now means
/// two, told apart by the clock — a tap under the threshold still stops and
/// pastes, and a hold past it opens the bubble for as long as the key is down,
/// its release closing the bubble and nothing else. Driven through the real
/// `handleFlagsChanged` with real flags-changed events, because the decision is
/// the ordering of a clock against a release and nothing smaller than that is
/// the thing that can be wrong.
@MainActor
final class LockedFnHoldTests: XCTestCase {
    private var storage: EphemeralDictation!
    private var hotkeys: HotkeyManager!
    /// Held strongly for the length of the test: `HotkeyManager.coordinator` is
    /// weak, and a fixture that let it go would put every gesture through a nil.
    private var coordinator: DictationCoordinator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = EphemeralDictation("LockedFnHoldTests")
        // The gesture starts behind the microphone-permission gate, and an
        // undetermined status would put a system prompt on the user's screen —
        // the same fence `DictationDurabilityTests` stands behind.
        try XCTSkipUnless(
            MicrophonePermission.status == .authorized,
            "a locked recording needs microphone permission already granted"
        )
    }

    override func tearDown() {
        hotkeys?.uninstall()
        hotkeys = nil
        coordinator = nil
        storage?.tearDown()
        storage = nil
        super.tearDown()
    }

    /// A recording on storage nothing else can see, with the hotkey manager
    /// installed on it. It hears nothing, so a release that really does end the
    /// dictation runs the pipeline as far as its no-speech branch and no
    /// further.
    private func recording() {
        let fixture = storage.gestures("LockedFnHoldTests")
        coordinator = fixture.coordinator
        hotkeys = fixture.hotkeys
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
    }

    /// Locked by the bubble's own glyph, which is the Space path itself — with
    /// the hotkey untouched, so nothing is mid-press.
    private func lockedRecording() {
        recording()
        hotkeys.toggleLockByClick()
        XCTAssertTrue(hotkeys.isLocked, "the fixture is a locked recording")
    }

    private func hotkey(down: Bool) -> NSEvent { fnKeyEvent(down: down) }

    /// Held past 300 ms: the bubble opens and stays open for as long as the key
    /// is down, the recording carries on, and letting go only closes it.
    func testHoldingOpensTheBubbleAndItsReleaseSubmitsNothing() async throws {
        lockedRecording()

        hotkeys.handleFlagsChanged(hotkey(down: true))
        XCTAssertFalse(hotkeys.isFnHoldingBubble, "nothing opens before the threshold")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(hotkeys.isFnHoldingBubble, "150 ms is the start-a-recording number, not this one")

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(hotkeys.isFnHoldingBubble, "held past 300 ms opens the bubble")
        XCTAssertTrue(hotkeys.isLocked, "opening the bubble is not an ending")

        hotkeys.handleFlagsChanged(hotkey(down: false))
        XCTAssertFalse(hotkeys.isFnHoldingBubble, "letting go closes it")
        // Past the release debounce, which is where a real ending would land.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(hotkeys.isLocked, "the release after a hold was swallowed — nothing submitted")
    }

    /// The commonest way into a locked recording: hold the key, press Space, and
    /// keep holding. The hold counts from the lock, so the bubble opens without
    /// letting go and pressing again — which is what it did before, leaving the
    /// gesture unreachable for anyone who locks the way the app teaches.
    func testHoldingThroughTheLockOpensTheBubbleToo() async throws {
        recording()

        hotkeys.handleFlagsChanged(hotkey(down: true))
        // Past the 150 ms that confirms a recording, the way a real hold is.
        try await Task.sleep(for: .milliseconds(200))
        hotkeys.toggleLockByClick()
        XCTAssertTrue(hotkeys.isLocked)
        XCTAssertFalse(hotkeys.isFnHoldingBubble, "the hold starts counting at the lock, not before it")

        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(hotkeys.isFnHoldingBubble, "still held past 300 ms → the bubble is open")

        hotkeys.handleFlagsChanged(hotkey(down: false))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(hotkeys.isFnHoldingBubble)
        XCTAssertTrue(hotkeys.isLocked, "the recording carries on")
    }

    /// Locking with the key down and letting go straight away is the shipped S2
    /// flow, and it still is: the release continues the recording, and no bubble
    /// was ever opened.
    func testLockingAndLettingGoAtOnceIsUnchanged() async throws {
        recording()

        hotkeys.handleFlagsChanged(hotkey(down: true))
        try await Task.sleep(for: .milliseconds(200))
        hotkeys.toggleLockByClick()
        hotkeys.handleFlagsChanged(hotkey(down: false))

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(hotkeys.isLocked, "hands free, as S2 has always been")
        XCTAssertFalse(hotkeys.isFnHoldingBubble)
    }

    /// Under 300 ms: unchanged. The bubble never opens and the release is the
    /// dictation's ending, which is the only ending a locked recording has.
    func testATapStillStopsAndPastes() async throws {
        lockedRecording()

        hotkeys.handleFlagsChanged(hotkey(down: true))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(hotkeys.isFnHoldingBubble)
        hotkeys.handleFlagsChanged(hotkey(down: false))

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(hotkeys.isLocked, "a tap ends the locked recording")
        XCTAssertFalse(hotkeys.isFnHoldingBubble)
    }

    /// A second press after a hold decides for itself: the latch that swallowed
    /// the hold's release is spent, so a tap now ends the dictation.
    func testATapAfterAHoldEndsIt() async throws {
        lockedRecording()

        hotkeys.handleFlagsChanged(hotkey(down: true))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(hotkeys.isFnHoldingBubble)
        hotkeys.handleFlagsChanged(hotkey(down: false))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(hotkeys.isLocked)

        hotkeys.handleFlagsChanged(hotkey(down: true))
        try await Task.sleep(for: .milliseconds(80))
        hotkeys.handleFlagsChanged(hotkey(down: false))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(hotkeys.isLocked, "the next tap is still the ending")
    }

    /// The two thresholds are different numbers on purpose: one decides whether
    /// a recording begins, the other what an already running one does.
    func testTheTwoThresholdsAreSeparate() {
        XCTAssertEqual(HotkeyManager.lockedHoldThreshold, .milliseconds(300))
        XCTAssertEqual(HotkeyManager.holdToRecordThreshold, .milliseconds(150))
        XCTAssertGreaterThan(HotkeyManager.lockedHoldThreshold, HotkeyManager.holdToRecordThreshold)
    }

    // MARK: - Every ending clears the lock (#225)

    /// The bug report: the paused bubble's `Stop recording` calls
    /// `finishWithoutPasting()` straight on the coordinator, with no route
    /// through this manager's own Fn-release/click paths — so `isLocked` used
    /// to stand true forever after, and the sidebar's dot with it. The fix
    /// fires synchronously inside `finish`, before the async pipeline even
    /// starts, so there is nothing to await here.
    func testFinishWithoutPastingClearsTheLock() {
        lockedRecording()

        coordinator.finishWithoutPasting()

        XCTAssertFalse(hotkeys.isLocked, "Stop recording must end the lock, not just the dictation")
        XCTAssertFalse(hotkeys.isFnHoldingBubble)
    }

    /// The issue's other named path: a discard reachable while locked (today,
    /// only via the Fn+R/Fn+Q read-aloud chord, which already cleared the lock
    /// itself first — this exercises the coordinator's own entry point
    /// directly, the shared seam every future caller gets for free).
    func testDiscardWhileLockedClearsTheLock() {
        lockedRecording()

        coordinator.discardRecording()

        XCTAssertFalse(hotkeys.isLocked, "a discard must end the lock along with the recording")
        XCTAssertFalse(hotkeys.isFnHoldingBubble)
    }

    /// The normal endings stay exactly as they were: both already clear the
    /// lock themselves before the coordinator's hook can fire, so the hook is
    /// a no-op for them (`testATapStillStopsAndPastes` above covers the
    /// Fn-release side) — restated here as the contrast the #225 fix must not
    /// disturb.
    func testTheLockGlyphsOwnUnlockStillClearsTheLockImmediately() {
        lockedRecording()

        hotkeys.toggleLockByClick()

        XCTAssertFalse(hotkeys.isLocked, "the lock glyph's own ending is untouched by #225")
    }
}
