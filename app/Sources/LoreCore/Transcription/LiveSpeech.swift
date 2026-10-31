@preconcurrency import AVFoundation
import FluidAudio
import os

/// One transcribed stretch of live speech, placed in the recording (#313 S13).
public struct SpeechLine: Sendable, Equatable {
    public let text: String
    /// Seconds into the recording where the detector heard the speech begin,
    /// or, for the next piece of speech that ran past 10 s, where that piece begins.
    public let start: Double
    /// Seconds into the recording where the line's audio ends.
    public let end: Double
    /// Each word, in seconds into the recording, from the model's own timings;
    /// empty when the backend gives none.
    public let words: [TimedWord]
}

/// Live capture → finished lines: the one live segmenter, behind the Mac's
/// meeting legs (`StreamingTranscriber`) and the iPhone's live text (#313 S13).
/// The caller pushes capture buffers as they arrive and is handed each line
/// the moment it is transcribed; `finish()` transcribes the speech still open
/// at the end.
///
/// Buffers are resampled to 16 kHz mono through one converter kept across
/// calls, then read one detector window at a time. A line keeps
/// `SileroVAD.leadInWindows` before the detected start, ends where the
/// detector ends the speech, or at 10 s of continuous speech, and speech that
/// ends at 1 s or less, its lead-in included, is dropped. The last words of
/// each line prime the next. The file pass segments differently on purpose
/// (`AudioFileSpeech`).
///
/// Not thread-safe: one caller at a time, each call awaited before the next.
/// Call it from a non-main actor or task: the calls run on the caller's
/// executor (`nonisolated(nonsending)`), so from `@MainActor` the resampling
/// and the windowing would run on the main thread.
public final class LiveSpeech {
    private static let windowSize = SileroVAD.windowSize
    /// Parakeet TDT requires >= 1s of audio; shorter segments produce unreliable output.
    /// Live only: its 10 s flush makes short pieces; the file pass keeps 0.5 s (`AudioFileSpeech`).
    static let minimumSpeechSamples = 16_000
    /// Longer chunks give the decoder more context and reduce WER
    /// (5s=41% vs 10s=36% on OpenOats benchmark).
    static let flushSamples = 10 * 16_000
    /// Trailing words carried across lines for decoder priming.
    private static let contextWordCount = 5

    private let backend: any TranscriptionBackend
    private let detector: any VoiceWindowDetector
    /// Names this stream in a resample failure event.
    private let source: DiagEvent.ResampleSource
    private let log = Logger(subsystem: "com.lore.app", category: "LiveSpeech")

    /// Resampler to 16 kHz mono Float32, kept across buffers (`AudioUtils.extractSamples`).
    private var converter: AVAudioConverter?
    /// Where each buffer's 16 kHz samples fall in the recording, in seconds.
    private var clock = FileFrameMap()
    /// 16 kHz samples received.
    private var received = 0
    /// Received samples short of a whole window, waiting for the next buffer.
    private var pending: [Float] = []
    /// The last windows heard before speech, with the sample each begins at.
    private var leadIn: [(start: Int, samples: [Float])] = []
    private var speech: [Float] = []
    /// The sample `speech` begins at.
    private var speechStart = 0
    /// Where the detector found the speech `speech` opens; nil for the piece after a 10 s flush.
    private var detectedAt: Int?
    private var isSpeaking = false
    /// Trailing words of the last line, priming the next.
    private var previousContext: String?

    /// Silero: `LiveSpeech(backend:detector: SileroWindowDetector(vad:), source:)`.
    public init(backend: any TranscriptionBackend, detector: any VoiceWindowDetector, source: DiagEvent.ResampleSource) {
        self.backend = backend
        self.detector = detector
        self.source = source
    }

    /// One capture buffer, in any PCM format, that begins `seconds` into the
    /// recording. `onLine` gets each line it finishes, in order, as soon as
    /// that line is transcribed. A buffer that cannot be converted is dropped
    /// (`resampleFailed` names `source`).
    public nonisolated(nonsending) func append(
        _ buffer: AVAudioPCMBuffer, at seconds: Double, onLine: (SpeechLine) -> Void
    ) async {
        guard let samples = AudioUtils.extractSamples(buffer, converter: &converter, source: source) else { return }
        clock.note(frame: seconds, rate: 1, atSample: received)
        received += samples.count
        pending += samples

        var offset = 0
        while pending.count - offset >= Self.windowSize {
            let windowStart = received - pending.count + offset
            if let line = await process(Array(pending[offset..<(offset + Self.windowSize)]), at: windowStart) {
                onLine(line)
            }
            offset += Self.windowSize
        }
        pending.removeFirst(offset)
        clock.forget(before: leadIn.first?.start ?? (speech.isEmpty ? received - pending.count : speechStart))
    }

    /// The speech still open, transcribed when it is over 1 s; the partial
    /// window waiting for more samples is not read. Starts over for a new
    /// stream, resampler included; the last words are kept.
    public nonisolated(nonsending) func finish() async -> SpeechLine? {
        let line = speech.count > Self.minimumSpeechSamples ? await transcribe() : nil
        converter = nil
        clock = FileFrameMap()
        received = 0
        pending = []
        leadIn = []
        speech = []
        detectedAt = nil
        isSpeaking = false
        detector.reset()
        return line
    }

    // MARK: - Segmenting

    private nonisolated(nonsending) func process(_ window: [Float], at windowStart: Int) async -> SpeechLine? {
        let event: VadStreamEvent?
        do {
            event = try await detector.read(window).event
        } catch {
            log.error("VAD error: \(error.localizedDescription)")
            return nil
        }

        if event?.kind == .speechStart, !isSpeaking {
            isSpeaking = true
            speech = leadIn.flatMap(\.samples)
            speechStart = leadIn.first?.start ?? windowStart
            detectedAt = windowStart
            leadIn = []
        }
        guard isSpeaking else {
            leadIn.append((windowStart, window))
            if leadIn.count > SileroVAD.leadInWindows { leadIn.removeFirst() }
            return nil
        }
        if speech.isEmpty { speechStart = windowStart }
        speech += window

        let ended = event?.kind == .speechEnd
        guard ended || speech.count >= Self.flushSamples else { return nil }
        if ended { isSpeaking = false }
        defer {
            speech.removeAll(keepingCapacity: true)
            detectedAt = nil
        }
        guard !ended || speech.count > Self.minimumSpeechSamples else { return nil }
        return await transcribe()
    }

    // MARK: - Transcribing

    /// `speech` as one line, or nil when the model hears nothing or fails.
    /// Word timings count from the line's first sample, its lead-in included.
    private nonisolated(nonsending) func transcribe() async -> SpeechLine? {
        let result: TranscriptionResult
        do {
            result = try await backend.transcribeDetailed(speech, previousContext: previousContext)
        } catch {
            log.error("ASR error: \(error.localizedDescription)")
            return nil
        }
        guard !result.text.isEmpty else { return nil }
        previousContext = result.text.split(separator: " ").suffix(Self.contextWordCount).joined(separator: " ")
        let first = speechStart
        let words = TranscribedToken.words(result.tokens).map { word in
            TimedWord(
                text: word.text,
                start: clock.fileFrame(atSample: first + Int((word.start * 16000).rounded())),
                end: clock.fileFrame(atSample: first + Int((word.end * 16000).rounded()))
            )
        }
        return SpeechLine(
            text: result.text,
            start: clock.fileFrame(atSample: detectedAt ?? first),
            end: clock.fileFrame(atSample: first + speech.count),
            words: words
        )
    }
}
