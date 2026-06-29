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
}
