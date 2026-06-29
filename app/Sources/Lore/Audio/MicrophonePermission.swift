@preconcurrency import AVFoundation

/// Pure microphone-permission core shared by the dictation and meeting paths.
///
/// Holds no engine state — callers map the result onto their own error channel.
/// `status` is a synchronous, cheap read safe to call on the dictation hot path
/// (hold-to-talk); only `request()` suspends, and only when status is `.notDetermined`.
enum MicrophonePermission {
    /// Current authorization without prompting. Synchronous.
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Show the system prompt (only meaningful when status is `.notDetermined`).
    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Shown after the user declines the just-presented system prompt.
    static let requestDeniedMessage =
        "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."

    /// Shown when permission was previously denied or is restricted by policy.
    static let deniedMessage =
        "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."

    /// Shown for an unrecognized future authorization status.
    static let unknownMessage = "Unable to verify microphone permission."

    /// Shown when capture starts but no audio frame arrives (the macOS 27 HAL stall).
    static let noAudioMessage =
        "Microphone is not producing audio. Check your input device in System Settings."

    /// Unified dictation mic-failure message. Deliberately does not presume a
    /// denied-vs-stuck cause (we can't reliably tell them apart) — it works for every
    /// failure. `deviceName` is the resolved input device; a trailing
    /// " Microphone"/" Mic" is stripped so "MacBook Air Microphone" reads naturally.
    /// Used by the dictation path only; the meeting path keeps the strings above.
    static func micUnavailableMessage(deviceName: String?) -> String {
        guard let name = strippedMicName(deviceName) else {
            return "The microphone is unavailable. Enable it, then restart the app after changing it."
        }
        return "The \(name) microphone is unavailable. Enable it, then restart the app after changing it."
    }

    private static func strippedMicName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        for suffix in [" microphone", " mic"] where trimmed.lowercased().hasSuffix(suffix) {
            let stripped = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : stripped
        }
        return trimmed
    }
}
