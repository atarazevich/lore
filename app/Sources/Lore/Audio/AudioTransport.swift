import CoreAudio

/// CoreAudio transport classification — the single table behind both the recording
/// allowlist (#39) and the diagnostic `DeviceKind` (#82).
///
/// These two once disagreed: the event model kept its own copy that called DisplayPort,
/// HDMI and Continuity-over-cable `.wired` while the allowlist excluded all three. A
/// diagnostic whose purpose is debugging the Continuity phantom must not describe the
/// phantom as a wired mic.
enum AudioTransport {

    /// Transports allowed for recording: built-in and wired. Anything else (Bluetooth,
    /// Continuity/iPhone, AirPlay, virtual) is wireless or unreliable and gets redirected.
    /// Allowlist, not Bluetooth-blocklist, so Continuity devices cannot slip through (#39).
    static let allowedForRecording: Set<UInt32> = [
        kAudioDeviceTransportTypeBuiltIn,
        kAudioDeviceTransportTypeUSB,
        kAudioDeviceTransportTypeThunderbolt,
        kAudioDeviceTransportTypeFireWire,
        kAudioDeviceTransportTypePCI,
    ]

    /// Transports that are wireless in behaviour, whatever the cable says. Continuity
    /// capture appears in *both* its wired and wireless forms: #39 exists because a
    /// Continuity iPhone impersonates a local mic.
    static let wireless: Set<UInt32> = [
        kAudioDeviceTransportTypeBluetooth,
        kAudioDeviceTransportTypeBluetoothLE,
        kAudioDeviceTransportTypeAirPlay,
        kAudioDeviceTransportTypeContinuityCaptureWired,
        kAudioDeviceTransportTypeContinuityCaptureWireless,
    ]
}

extension DiagEvent.DeviceKind {
    /// Collapse a CoreAudio transport type to a transport class, so a device's *name*
    /// ("Sam's AirPods Pro") never reaches a diagnostic event.
    ///
    /// Classified against the same sets that decide what may record, so the diagnostic
    /// and the recording rule cannot drift apart. An unreadable transport reads as
    /// `.virtual`: the conservative bucket, since aggregate and tap devices land there.
    init(transport: UInt32?) {
        guard let transport else {
            self = .virtual
            return
        }
        if transport == kAudioDeviceTransportTypeBuiltIn {
            self = .builtIn
        } else if AudioTransport.wireless.contains(transport) {
            self = .wireless
        } else if AudioTransport.allowedForRecording.contains(transport) {
            self = .wired
        } else {
            self = .virtual
        }
    }
}
