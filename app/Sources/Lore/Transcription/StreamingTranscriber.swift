@preconcurrency import AVFoundation
import LoreCore
import LoreFormat
import os

/// Consumes an audio buffer stream and hands each finished line's text on.
/// The segmenting is `LiveSpeech`'s, shared with the iPhone (#313 S13).
final class StreamingTranscriber: @unchecked Sendable {
    private let speech: LiveSpeech
    private let speaker: Speaker
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void
    private let log = Logger(subsystem: "com.lore", category: "StreamingTranscriber")

    init(
        backend: any TranscriptionBackend,
        detector: any VoiceWindowDetector,
        speaker: Speaker,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) {
        // Names this stream in a resample failure event.
        let source: DiagEvent.ResampleSource = switch speaker {
        case .you: .meetingMic
        case .them, .remote: .meetingSystem
        }
        self.speech = LiveSpeech(backend: backend, detector: detector, source: source)
        self.speaker = speaker
        self.onPartial = onPartial
        self.onFinal = onFinal
    }

    /// Main loop: reads audio buffers until the stream ends, then the speech still open.
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        // The Mac reads no line times; the stream's own frames place each buffer.
        var seconds = 0.0
        for await buffer in stream {
            await speech.append(buffer, at: seconds, onLine: deliver)
            seconds += Double(buffer.frameLength) / buffer.format.sampleRate
        }
        if let line = await speech.finish() { deliver(line) }
    }

    private func deliver(_ line: SpeechLine) {
        // A live meeting utterance. Implicit `.auto` already redacts dynamic
        // strings, but the annotation is the standard and survives refactors (#82).
        log.debug("[\(self.speaker.storageKey, privacy: .public)] transcribed: \(line.text, privacy: .private)")
        onFinal(line.text)
    }
}
