import XCTest
@testable import LoreKit

/// #223: Fn+K stands behind one master switch, off on every fresh install.
///
/// `toggleOperatorAddressed` is where the switch is tested because it is the
/// one chokepoint every route to the flag goes through — the local key monitor,
/// the CGEvent tap and the bubble's own `K` click all call exactly this. The
/// rail's side of the switch (no letter, armed or hint) is
/// `RecordingBubbleRailTests`; the default's side is `SettingsStoreTests`.
@MainActor
final class OperatorSendSwitchTests: XCTestCase {

    private var storage: EphemeralDictation!
    /// Held for the test's length: the coordinator is what the settings hang
    /// off, and a recording has to still be running when the toggle is tried.
    private var coordinator: DictationCoordinator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = EphemeralDictation("OperatorSendSwitchTests")
        // Arming happens inside a confirmed recording, which starts behind the
        // microphone-permission gate; undetermined would put a system prompt on
        // the user's screen.
        try XCTSkipUnless(
            MicrophonePermission.status == .authorized,
            "the arming gesture needs microphone permission already granted"
        )
    }

    override func tearDown() {
        coordinator = nil
        storage.tearDown()
        storage = nil
        super.tearDown()
    }

    /// A confirmed recording whose settings carry the switch in one position.
    @discardableResult
    private func makeRecording(operatorSend: Bool) -> DictationCoordinator {
        let coordinator = storage.coordinator(backend: StubTranscriptionBackend(transcript: ""))
        let settings = isolatedSettings("OperatorSendSwitchTests", defaults: storage.defaults)
        settings.operatorSendEnabled = operatorSend
        coordinator.settings = settings
        coordinator.startPreBuffer()
        coordinator.confirmRecording()
        XCTAssertEqual(coordinator.state, .recording, "the fixture is a live recording")
        self.coordinator = coordinator
        return coordinator
    }

    /// With the switch on, nothing about #122 changed: the same toggle idiom as
    /// the pre-paste modes — pressed twice, off again.
    func testTheKeyStillArmsWhileTheSwitchIsOn() {
        let coordinator = makeRecording(operatorSend: true)

        coordinator.toggleOperatorAddressed()
        XCTAssertTrue(coordinator.pendingOperatorAddressed)
        XCTAssertTrue(coordinator.operatorAddressedDisplayed, "the K letter stands lit")

        coordinator.toggleOperatorAddressed()
        XCTAssertFalse(coordinator.pendingOperatorAddressed, "pressed twice → off")
    }

    /// With the switch off the same call marks nothing — the key, the tap and
    /// the bubble's click all arrive here, so all three are inert at once.
    func testNothingArmsWhileTheSwitchIsOff() {
        let coordinator = makeRecording(operatorSend: false)

        coordinator.toggleOperatorAddressed()

        XCTAssertFalse(coordinator.pendingOperatorAddressed)
        XCTAssertFalse(coordinator.operatorAddressedDisplayed, "no letter to light")
    }

    /// Flipped off mid-recording, the next press does nothing — the switch is
    /// read at the press, never remembered from the start of the dictation.
    func testFlippingTheSwitchOffMidRecordingStopsTheNextPress() {
        let coordinator = makeRecording(operatorSend: true)
        coordinator.settings?.operatorSendEnabled = false

        coordinator.toggleOperatorAddressed()

        XCTAssertFalse(coordinator.pendingOperatorAddressed)
    }

    /// A coordinator that cannot read the switch behaves as off. The switch is
    /// off on every fresh install, so "unknown" may not be the generous answer.
    func testTheFlagCannotBeSetWithoutSettingsToReadTheSwitchFrom() {
        let coordinator = makeRecording(operatorSend: true)
        coordinator.settings = nil

        coordinator.toggleOperatorAddressed()

        XCTAssertFalse(coordinator.pendingOperatorAddressed)
    }
}
