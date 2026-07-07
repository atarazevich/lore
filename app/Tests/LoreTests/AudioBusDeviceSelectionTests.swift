import CoreAudio
import XCTest
@testable import LoreKit

/// Pure allowlist selection (#39/D-030), separated from HAL probing so it is testable
/// without CoreAudio (#64). Device probes are hand-built snapshots.
final class AudioBusDeviceSelectionTests: XCTestCase {

    private static let canonicalBuiltInUID = "BuiltInMicrophoneDevice"

    private func builtIn(_ id: AudioDeviceID, name: String = "MacBook Pro Microphone") -> AudioBus.InputDeviceProbe {
        AudioBus.InputDeviceProbe(id: id, name: name, transport: kAudioDeviceTransportTypeBuiltIn, uid: Self.canonicalBuiltInUID)
    }

    private func phantom(_ id: AudioDeviceID, name: String = "iPhone Microphone") -> AudioBus.InputDeviceProbe {
        // Continuity phantom: reports built-in transport but not the canonical UID (#39).
        AudioBus.InputDeviceProbe(id: id, name: name, transport: kAudioDeviceTransportTypeBuiltIn, uid: "ContinuityCaptureDevice-1")
    }

    private func usb(_ id: AudioDeviceID, name: String = "USB Mic") -> AudioBus.InputDeviceProbe {
        AudioBus.InputDeviceProbe(id: id, name: name, transport: kAudioDeviceTransportTypeUSB, uid: "usb-\(id)")
    }

    private func bluetooth(_ id: AudioDeviceID, name: String = "AirPods Pro") -> AudioBus.InputDeviceProbe {
        AudioBus.InputDeviceProbe(id: id, name: name, transport: kAudioDeviceTransportTypeBluetooth, uid: "bt-\(id)")
    }

    func testNoDevicesReturnsNil() {
        XCTAssertNil(AudioBus.selectInputDevice(from: [], requested: 5, systemDefault: 5))
    }

    func testRequestedWiredDeviceIsKept() {
        let result = AudioBus.selectInputDevice(
            from: [builtIn(102), usb(200)], requested: 200, systemDefault: 102
        )
        XCTAssertEqual(result?.deviceID, 200)
        XCTAssertEqual(result?.redirectedToBuiltIn, false)
    }

    func testRequestedBluetoothRedirectsToBuiltInWithHint() {
        let result = AudioBus.selectInputDevice(
            from: [builtIn(102), bluetooth(300)], requested: 300, systemDefault: 300
        )
        XCTAssertEqual(result?.deviceID, 102)
        XCTAssertEqual(result?.redirectedToBuiltIn, true)
    }

    func testStaleRequestedFallsBackToSystemDefault() {
        // Requested device no longer exists; default is wired — use it.
        let result = AudioBus.selectInputDevice(
            from: [builtIn(102), usb(200)], requested: 999, systemDefault: 200
        )
        XCTAssertEqual(result?.deviceID, 200)
        XCTAssertEqual(result?.redirectedToBuiltIn, false)
    }

    func testVanishedRequestedAndDefaultSelectBuiltInWithoutHint() {
        // Both the requested device and the system default vanished (candidate == 0):
        // the built-in fallback wins over the wired one, with no wireless hint.
        let result = AudioBus.selectInputDevice(
            from: [usb(200), builtIn(102)], requested: 999, systemDefault: 888
        )
        XCTAssertEqual(result?.deviceID, 102)
        XCTAssertEqual(result?.redirectedToBuiltIn, false)
    }

    func testBluetoothDefaultRedirectsToBuiltIn() {
        let result = AudioBus.selectInputDevice(
            from: [builtIn(102), bluetooth(300)], requested: 0, systemDefault: 300
        )
        XCTAssertEqual(result?.deviceID, 102)
        XCTAssertEqual(result?.redirectedToBuiltIn, true)
    }

    func testContinuityPhantomDefaultRedirectsToCanonicalBuiltInWithoutHint() {
        // Phantom passes the transport allowlist but fails the UID check — it must be
        // redirected to the real built-in mic WITHOUT the wireless-compression hint (#39).
        let result = AudioBus.selectInputDevice(
            from: [phantom(146), builtIn(102)], requested: 0, systemDefault: 146
        )
        XCTAssertEqual(result?.deviceID, 102)
        XCTAssertEqual(result?.redirectedToBuiltIn, false)
    }

    func testPhantomOnlyBuiltInIsLastResortForWirelessCandidate() {
        // No canonical built-in mic: the first built-in-transport device (the phantom)
        // is the fallback, and a Bluetooth candidate still reports the redirect hint.
        let result = AudioBus.selectInputDevice(
            from: [bluetooth(300), phantom(146)], requested: 300, systemDefault: 300
        )
        XCTAssertEqual(result?.deviceID, 146)
        XCTAssertEqual(result?.redirectedToBuiltIn, true)
    }

    func testNoBuiltInFallsBackToFirstWired() {
        // Mac mini: no built-in mic at all — first allowed wired input wins.
        let result = AudioBus.selectInputDevice(
            from: [bluetooth(300), usb(200)], requested: 300, systemDefault: 300
        )
        XCTAssertEqual(result?.deviceID, 200)
        XCTAssertEqual(result?.redirectedToBuiltIn, false)
    }

    func testOnlyBluetoothKeepsCandidate() {
        let result = AudioBus.selectInputDevice(
            from: [bluetooth(300)], requested: 0, systemDefault: 300
        )
        XCTAssertEqual(result?.deviceID, 300)
        XCTAssertEqual(result?.redirectedToBuiltIn, false)
    }

    func testOnlyBluetoothWithoutCandidateReturnsNil() {
        // Devices exist but neither the request nor the default resolves, and nothing
        // is allowed — no usable input.
        let result = AudioBus.selectInputDevice(
            from: [bluetooth(300)], requested: 999, systemDefault: nil
        )
        XCTAssertNil(result)
    }

    func testUnreadableTransportRedirectsWithoutHint() {
        // Candidate's transport could not be read: not allowed, but the redirect hint
        // (wireless compression warning) must not fire either.
        let unreadable = AudioBus.InputDeviceProbe(id: 400, name: "Mystery", transport: nil, uid: nil)
        let result = AudioBus.selectInputDevice(
            from: [unreadable, builtIn(102)], requested: 400, systemDefault: 400
        )
        XCTAssertEqual(result?.deviceID, 102)
        XCTAssertEqual(result?.redirectedToBuiltIn, false)
    }
}

/// Pure decision behind `AudioBus.subscribe` (#66, D-030 hardening): while capture is
/// running, a new subscriber joins the pinned device — the requested device isn't even
/// a parameter, so a second consumer (dictation during a meeting) can never switch it.
final class AudioBusSubscribeDecisionTests: XCTestCase {

    func testSubscriberWhileRunningJoinsPinnedDevice() {
        XCTAssertEqual(AudioBus.subscribeDecision(captureRunning: true), .joinPinnedDevice)
    }

    func testSubscriberWhileStoppedStartsCapture() {
        XCTAssertEqual(AudioBus.subscribeDecision(captureRunning: false), .startCapture)
    }
}
