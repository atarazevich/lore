@preconcurrency import AVFoundation
import FluidAudio
import os

/// Consumes an audio buffer stream, detects speech via Silero VAD,
/// and transcribes completed speech segments via Parakeet-TDT.
final class StreamingTranscriber: @unchecked Sendable {
    private enum Backend: @unchecked Sendable {
        case parakeet(AsrManager)
        case qwen3(Qwen3AsrManager, Qwen3AsrConfig.Language?)
    }

    private let backend: Backend
    private let vadManager: VadManager
    private let speaker: Speaker
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void
    private let log = Logger(subsystem: "com.lore.app", category: "StreamingTranscriber")

    private var converter: AVAudioConverter?

    init(
        asrManager: AsrManager,
        vadManager: VadManager,
        speaker: Speaker,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) {
        self.backend = .parakeet(asrManager)
        self.vadManager = vadManager
        self.speaker = speaker
        self.onPartial = onPartial
        self.onFinal = onFinal
    }

    init(
        qwen3Manager: Qwen3AsrManager,
        qwenLanguage: Qwen3AsrConfig.Language?,
        vadManager: VadManager,
        speaker: Speaker,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) {
        self.backend = .qwen3(qwen3Manager, qwenLanguage)
        self.vadManager = vadManager
        self.speaker = speaker
        self.onPartial = onPartial
        self.onFinal = onFinal
    }

    /// Silero VAD expects chunks of 4096 samples (256ms at 16kHz).
    private static let vadChunkSize = 4096
    private static let minimumSpeechSamples = 8000
    private static let prerollChunkCount = 2
    /// Flush speech for transcription every ~3 seconds (48,000 samples at 16kHz).
    private static let flushInterval = 48_000

    /// Main loop: reads audio buffers, runs VAD, transcribes speech segments.
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var recentChunks: [[Float]] = []
        var isSpeaking = false
        var bufferCount = 0

        for await buffer in stream {
            bufferCount += 1
            if bufferCount <= 3 {
                let fmt = buffer.format
                diagLog("[\(speaker.rawValue)] buffer #\(bufferCount): frames=\(buffer.frameLength) sr=\(fmt.sampleRate) ch=\(fmt.channelCount) interleaved=\(fmt.isInterleaved) common=\(fmt.commonFormat.rawValue)")
            }

            guard let samples = AudioUtils.extractSamples(buffer, converter: &converter) else { continue }

            if bufferCount <= 3 {
                let maxVal = samples.max() ?? 0
                diagLog("[\(speaker.rawValue)] samples: count=\(samples.count) max=\(maxVal)")
            }

            vadBuffer.append(contentsOf: samples)

            while vadBuffer.count >= Self.vadChunkSize {
                let chunk = Array(vadBuffer.prefix(Self.vadChunkSize))
                vadBuffer.removeFirst(Self.vadChunkSize)
                let wasSpeaking = isSpeaking

                var startedSpeech = false
                var endedSpeech = false
                do {
                    let result = try await vadManager.processStreamingChunk(
                        chunk,
                        state: vadState,
                        config: .default,
                        returnSeconds: true,
                        timeResolution: 2
                    )
                    vadState = result.state

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            if !wasSpeaking {
                                isSpeaking = true
                                startedSpeech = true
                                speechSamples = recentChunks.suffix(Self.prerollChunkCount).flatMap { $0 }
                                diagLog("[\(self.speaker.rawValue)] speech start")
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
                        diagLog("[\(self.speaker.rawValue)] speech end, samples=\(speechSamples.count)")
                        if speechSamples.count > Self.minimumSpeechSamples {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await transcribeSegment(segment)
                        } else {
                            speechSamples.removeAll(keepingCapacity: true)
                        }
                    } else if isSpeaking {

                        // Flush every ~3s for near-real-time output during continuous speech
                        if speechSamples.count >= Self.flushInterval {
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

    private func transcribeSegment(_ samples: [Float]) async {
        do {
            let text: String
            switch backend {
            case .parakeet(let asrManager):
                let result = try await asrManager.transcribe(samples)
                text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .qwen3(let qwen3Manager, let qwenLanguage):
                text = try await qwen3Manager.transcribe(
                    audioSamples: samples,
                    language: qwenLanguage,
                    maxNewTokens: 512
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else { return }
            log.info("[\(self.speaker.rawValue)] transcribed: \(text.prefix(80))")
            onFinal(text)
        } catch {
            log.error("ASR error: \(error.localizedDescription)")
        }
    }

}
