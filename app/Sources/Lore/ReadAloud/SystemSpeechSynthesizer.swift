import AVFoundation
import Foundation
import os

/// The free/offline Read Aloud engine (#105): renders an `AVSpeechUtterance`
/// to a CAF file off-screen and hands the file over, so system voices flow
/// through the exact same queue → temp file → `AVQueuePlayer` pipeline as
/// Speechify audio (same panel, same pitch-preserving rate). Chosen over
/// live `speak(_:)` because a second live audio path would need its own
/// pause/rate/queue plumbing.
struct SystemSpeechSynthesizer: SpeechSynthesizing {
    private static let log = Logger(subsystem: "com.lore.app", category: "SystemSpeech")

    enum SystemSpeechError: Error, LocalizedError {
        case renderFailed
        var errorDescription: String? { "System voice rendering failed" }
    }

    /// `voice` is an `AVSpeechSynthesisVoice` identifier or
    /// `ReadAloudVoiceChoice.systemAutoID`; `language` is the detected code
    /// used for the auto pick. `model`/`apiKey` are Speechify concepts and
    /// ignored here.
    func synthesize(
        text: String, voice: String, model: String, language: String?, apiKey: String
    ) async throws -> URL {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolveVoice(id: voice, languageCode: language)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lore-SystemSpeech-\(UUID().uuidString).caf")

        let synthesizer = AVSpeechSynthesizer()
        let state = RenderState(url: url)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                synthesizer.write(utterance) { buffer in
                    state.consume(buffer, continuation: continuation)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        // Keep the synthesizer alive for the whole render — `write` does not
        // retain it on all OS versions.
        withExtendedLifetime(synthesizer) {}

        // Close the AVAudioFile so the header is final before the caller
        // reads the file's duration.
        state.finish()
        return url
    }

    /// Explicit identifier wins; the auto pick tries the exact code, then any
    /// installed voice whose language shares the prefix ("de" → "de-DE");
    /// nil lets the utterance fall back to the system default voice.
    static func resolveVoice(id: String, languageCode: String?) -> AVSpeechSynthesisVoice? {
        if id != ReadAloudVoiceChoice.systemAutoID {
            return AVSpeechSynthesisVoice(identifier: id)
        }
        guard let languageCode else { return nil }
        if let exact = AVSpeechSynthesisVoice(language: languageCode) {
            return exact
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .first { $0.language.hasPrefix(languageCode) }
    }

    /// Accumulates PCM buffers into the file and resumes the continuation
    /// exactly once. `write`'s callback arrives off-main and is not
    /// `@Sendable`-annotated; the lock makes the mutation safe anyway.
    private final class RenderState: @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var file: AVAudioFile?
        private var finished = false

        init(url: URL) {
            self.url = url
        }

        /// Release the AVAudioFile (closing it) once rendering is over.
        func finish() {
            lock.lock()
            defer { lock.unlock() }
            file = nil
        }

        func consume(_ buffer: AVAudioBuffer, continuation: CheckedContinuation<Void, any Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }

            guard let pcm = buffer as? AVAudioPCMBuffer else {
                finished = true
                continuation.resume(throwing: SystemSpeechError.renderFailed)
                return
            }
            // A zero-length buffer is the completion signal.
            guard pcm.frameLength > 0 else {
                finished = true
                if file == nil {
                    continuation.resume(throwing: SystemSpeechError.renderFailed)
                } else {
                    continuation.resume(returning: ())
                }
                return
            }
            do {
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
                }
                try file?.write(from: pcm)
            } catch {
                finished = true
                SystemSpeechSynthesizer.log.error(
                    "system speech write failed: \(error.localizedDescription, privacy: .public)"
                )
                continuation.resume(throwing: error)
            }
        }
    }
}
