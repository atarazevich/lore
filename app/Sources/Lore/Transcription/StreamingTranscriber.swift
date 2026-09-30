@preconcurrency import AVFoundation
import FluidAudio
import os

/// Consumes an audio buffer stream, detects speech via Silero VAD,
/// and transcribes completed speech segments via the TranscriptionBackend protocol.
final class StreamingTranscriber: @unchecked Sendable {
    private let backend: any TranscriptionBackend
    private let vadManager: VadManager
    private let speaker: Speaker
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void
    private let log = Logger(subsystem: "com.lore", category: "StreamingTranscriber")

    /// Resampler to 16kHz mono Float32, kept across buffers (AudioUtils.extractSamples).
    private var converter: AVAudioConverter?
    /// Names this stream in a resample failure event.
    private var resampleSource: DiagEvent.ResampleSource {
        switch speaker {
        case .you: .meetingMic
        case .them, .remote: .meetingSystem
        }
    }

    init(
        backend: any TranscriptionBackend,
        vadManager: VadManager,
        speaker: Speaker,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) {
        self.backend = backend
        self.vadManager = vadManager
        self.speaker = speaker
        self.onPartial = onPartial
        self.onFinal = onFinal
    }

    private static let vadChunkSize = SileroVAD.windowSize
    /// Parakeet TDT requires >= 1s of audio; shorter segments produce unreliable output.
    /// Live only: its 10 s flush makes short pieces; the file pass keeps 0.5 s (`AudioFileSpeech`).
    private static let minimumSpeechSamples = 16_000
    private static let prerollChunkCount = SileroVAD.leadInWindows
    /// Flush interval in 16kHz samples. Longer chunks give the decoder more
    /// context and reduce WER (5s=41% vs 10s=36% on OpenOats benchmark).
    private let flushInterval = 10 * 16_000
    /// Number of trailing words to carry across segment boundaries for decoder priming.
    private static let contextWordCount = 5

    /// Main loop: reads audio buffers, runs VAD, transcribes speech segments.
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        let detector = SileroWindowDetector(vad: vadManager)
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var vadReadIndex = 0
        var recentChunks: [[Float]] = []
        var isSpeaking = false
        var bufferCount = 0

        for await buffer in stream {
            bufferCount += 1
            if bufferCount <= 3 {
                let fmt = buffer.format
                log.debug("[\(self.speaker.storageKey, privacy: .public)] buffer #\(bufferCount, privacy: .public): frames=\(buffer.frameLength, privacy: .public) sr=\(fmt.sampleRate, privacy: .public) ch=\(fmt.channelCount, privacy: .public)")
            }

            guard let samples = AudioUtils.extractSamples(buffer, converter: &converter, source: resampleSource) else { continue }

            if bufferCount <= 3 {
                let maxVal = samples.max() ?? 0
                log.debug("[\(self.speaker.storageKey, privacy: .public)] samples: count=\(samples.count, privacy: .public) max=\(maxVal, privacy: .public)")
            }

            vadBuffer.append(contentsOf: samples)

            while vadBuffer.count - vadReadIndex >= Self.vadChunkSize {
                let chunk = Array(vadBuffer[vadReadIndex..<(vadReadIndex + Self.vadChunkSize)])
                vadReadIndex += Self.vadChunkSize

                // Compact when we've consumed more than half to bound memory growth
                if vadReadIndex > vadBuffer.count / 2 {
                    vadBuffer.removeFirst(vadReadIndex)
                    vadReadIndex = 0
                }
                let wasSpeaking = isSpeaking

                var startedSpeech = false
                var endedSpeech = false
                do {
                    let result = try await detector.read(chunk)

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            if !wasSpeaking {
                                isSpeaking = true
                                startedSpeech = true
                                speechSamples = recentChunks.suffix(Self.prerollChunkCount).flatMap { $0 }
                                log.debug("[\(self.speaker.storageKey, privacy: .public)] speech start")
                            }

                        case .speechEnd:
                            endedSpeech = wasSpeaking || isSpeaking
                        }
                    }

                    if wasSpeaking || startedSpeech || endedSpeech {
                        speechSamples.append(contentsOf: chunk)
                        recentChunks.removeAll(keepingCapacity: true)
                    } else {
                        recentChunks.append(chunk)
                        if recentChunks.count > Self.prerollChunkCount {
                            recentChunks.removeFirst(recentChunks.count - Self.prerollChunkCount)
                        }
                    }

                    if endedSpeech {
                        isSpeaking = false
                        log.debug("[\(self.speaker.storageKey, privacy: .public)] speech end, samples=\(speechSamples.count, privacy: .public)")
                        if speechSamples.count > Self.minimumSpeechSamples {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await transcribeSegment(segment)
                        } else {
                            speechSamples.removeAll(keepingCapacity: true)
                        }
                    } else if isSpeaking {

                        // Flush on long continuous speech (see flushInterval)
                        if speechSamples.count >= flushInterval {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await transcribeSegment(segment)
                        }
                    }
                } catch {
                    log.error("VAD error: \(error.localizedDescription)")
                }
            }
        }

        if speechSamples.count > Self.minimumSpeechSamples {
            await transcribeSegment(speechSamples)
        }
    }

    /// Trailing words from the last transcribed segment, used to prime the next segment's decoder.
    private var previousContext: String?

    private func transcribeSegment(_ samples: [Float]) async {
        do {
            let text = try await backend.transcribe(samples, previousContext: previousContext)
            guard !text.isEmpty else { return }
            // A live meeting utterance. Implicit `.auto` already redacts dynamic
            // strings, but the annotation is the standard and survives refactors (#82).
            log.debug("[\(self.speaker.storageKey, privacy: .public)] transcribed: \(text, privacy: .private)")
            // Store trailing words for cross-segment context
            let words = text.split(separator: " ")
            previousContext = words.suffix(Self.contextWordCount).joined(separator: " ")
            onFinal(text)
        } catch {
            log.error("ASR error: \(error.localizedDescription)")
        }
    }
}
