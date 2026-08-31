import AppKit
import XCTest
@testable import LoreKit

/// A recorded talk key reaches lore as a key-down and a key-up rather than as a
/// flag (#226), and it has to mean exactly what a modifier press has always
/// meant. Driven through the real `HotkeyManager` for the same reason
/// `LockedFnHoldTests` is: the thing that can be wrong is which gesture a press
/// turns into, and nothing smaller than the manager decides that.
@MainActor
final class RecordedHotkeyTests: XCTestCase {
    private var storage: EphemeralDictation!
    private var hotkeys: HotkeyManager!
    /// Held strongly: `HotkeyManager.coordinator` is weak.
    private var coordinator: DictationCoordinator!
    private var settings: AppSettings!

    /// F13 — a key with no media job, so it arrives as a key-down whatever the
    /// keyboard's F-row setting says.
    private static let f13: UInt16 = 105

    override func setUp() {
        super.setUp()
        storage = EphemeralDictation("RecordedHotkeyTests")
    }

    override func tearDown() {
        hotkeys?.uninstall()
        hotkeys = nil
        coordinator = nil
        settings = nil
        storage?.tearDown()
        storage = nil
        super.tearDown()
    }

    private func install(talkKey: HotkeyKey) {
        let fixture = storage.gestures("RecordedHotkeyTests", talkKey: talkKey)
        coordinator = fixture.coordinator
        settings = fixture.settings
        hotkeys = fixture.hotkeys
    }

    /// The mic gate the capture paths stand behind — an undetermined status
    /// would put a system prompt on the user's screen.
    private func requireMicrophone() throws {
        try XCTSkipUnless(
            MicrophonePermission.status == .authorized,
            "starting a capture needs microphone permission already granted"
        )
    }

    /// The talk key is F13: an Fn press is now somebody else's key, and the
    /// flags path must let it go by. Otherwise both keys would open the mic.
    func testAModifierPressIsIgnoredWhileARecordedKeyIsTheTalkKey() {
        install(talkKey: .custom(keyCode: Self.f13))

        hotkeys.handleFlagsChanged(fnKeyEvent(down: true))

        XCTAssertFalse(coordinator.isPreBuffering, "Fn is not the talk key any more")
        XCTAssertEqual(coordinator.state, .idle)
    }

    /// The press opens the microphone and the hold past the threshold confirms
    /// the recording — the same two steps a modifier hold takes.
    func testARecordedKeyHeldPastTheThresholdRecords() async throws {
        try requireMicrophone()
        install(talkKey: .custom(keyCode: Self.f13))

        hotkeys.handleRecordedKey(down: true)
        XCTAssertTrue(coordinator.isPreBuffering, "the press opens the mic straight away")

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(coordinator.state, .recording, "held past 150 ms → recording")
    }

    /// Auto-repeat is the same press still down. A second start here would
    /// throw away the audio already captured and begin again mid-sentence.
    func testAutoRepeatIsTheSamePressAndStartsNothingNew() async throws {
        try requireMicrophone()
        install(talkKey: .custom(keyCode: Self.f13))

        hotkeys.handleRecordedKey(down: true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(coordinator.state, .recording)

        hotkeys.handleRecordedKey(down: true)
        XCTAssertEqual(coordinator.state, .recording, "a repeat is not a new press")
        XCTAssertFalse(coordinator.isPreBuffering)
    }

    /// A press shorter than the threshold is a tap: the microphone closes and
    /// nothing is transcribed — exactly what a tapped Fn does.
    func testATapClosesTheMicrophoneAndRecordsNothing() async throws {
        try requireMicrophone()
        install(talkKey: .custom(keyCode: Self.f13))

        hotkeys.handleRecordedKey(down: true)
        XCTAssertTrue(coordinator.isPreBuffering)
        hotkeys.handleRecordedKey(down: false)

        XCTAssertFalse(coordinator.isPreBuffering, "the tap cancelled the pre-buffer")
        XCTAssertEqual(coordinator.state, .idle)
    }

    /// A key-up with no press behind it — the recorder was open when the key
    /// went down, or the tap came up mid-gesture. It must not end a dictation
    /// that this key never started.
    func testAReleaseWithNoPressBehindItDoesNothing() {
        install(talkKey: .custom(keyCode: Self.f13))

        hotkeys.handleRecordedKey(down: false)

        XCTAssertFalse(coordinator.isPreBuffering)
        XCTAssertEqual(coordinator.state, .idle)
    }

    // MARK: - While a recorder is open

    /// While a key recorder is open the press is the user choosing a key, not
    /// holding one: nothing may start. This is what stops Settings from taking
    /// a dictation while the user is picking the very key they pressed.
    func testASuspendedManagerStartsNothing() async throws {
        try requireMicrophone()
        install(talkKey: .fn)
        hotkeys.isSuspended = true

        hotkeys.handleFlagsChanged(fnKeyEvent(down: true))
        XCTAssertFalse(coordinator.isPreBuffering, "the recorder is open — this press is a choice")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(coordinator.state, .idle)

        // And the release finds nothing to unwind.
        hotkeys.handleFlagsChanged(fnKeyEvent(down: false))
        XCTAssertEqual(coordinator.state, .idle)

        // Closing the recorder gives the key straight back.
        hotkeys.isSuspended = false
        hotkeys.handleFlagsChanged(fnKeyEvent(down: true))
        XCTAssertTrue(coordinator.isPreBuffering)
        hotkeys.handleFlagsChanged(fnKeyEvent(down: false))
    }

    /// The other half of the same rule, and the one that bites harder: the tap
    /// *swallows* a recorded talk key on every press, so a suspension that only
    /// stopped the gesture would still eat the keystroke — and the recorder,
    /// listening on an NSEvent monitor downstream of the tap, would wait
    /// forever for a key the user is pressing. Suspended, the key is nobody's:
    /// `recordedTalkKeyCode` goes nil and the tap's branch is not entered at
    /// all, which is what lets the event through to the prompt.
    func testASuspendedManagerStopsSwallowingTheRecordedKey() {
        install(talkKey: .custom(keyCode: Self.f13))
        XCTAssertEqual(
            hotkeys.recordedTalkKeyCode, Self.f13,
            "the tap owns this key while the app is listening for a hold"
        )

        hotkeys.isSuspended = true
        XCTAssertNil(
            hotkeys.recordedTalkKeyCode,
            "a recorder is open — the key has to reach it, so the tap must not consume it"
        )

        hotkeys.isSuspended = false
        XCTAssertEqual(hotkeys.recordedTalkKeyCode, Self.f13, "and the tap owns it again after")
    }

    /// Fn and Right Option never enter that branch in the first place: they are
    /// flags, and the tap's key-up half exists for the recorded key alone.
    func testTheTapOwnsNoKeyWhenTheTalkKeyIsAModifier() {
        for key in [HotkeyKey.fn, .rightOption, .custom(keyCode: 54)] {
            install(talkKey: key)
            XCTAssertNil(hotkeys.recordedTalkKeyCode, key.displayName)
            hotkeys.uninstall()
        }
    }
}
