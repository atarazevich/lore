@preconcurrency import AVFoundation
import FluidAudio

/// Up to 30 seconds of a file, resampled to the 16 kHz mono the models take.
struct AudioChunk {
    /// Where the chunk starts, in the file's own frames.
    let startFrame: Int64
    /// Frames the chunk covered in the file, which the samples no longer count.
    let frameCount: Int64
    /// The rate `startFrame` and `frameCount` are counted at.
    let frameRate: Double
    let samples: [Float]
}

/// Where the 16 kHz samples of a read fall in the file they came from. Each
/// block notes the sample its samples begin at and the file frame that is;
/// a sample maps from the block it falls in, so a hole (a block that decoded
/// to nothing) moves the file frames on while the samples run on without it.
/// Shared by the transcript pass and the speaker pass, so their timings land
/// on the same clock (#269).
struct FileFrameMap {
    private struct Origin {
        let sample: Int
        let frame: Int64
    }

    private var origins: [Origin] = []
    /// The file's own rate, from its first block.
    private var frameRate: Double?

    /// `chunk`'s samples begin at `sample`.
    mutating func note(_ chunk: AudioChunk, atSample sample: Int) {
        frameRate = frameRate ?? chunk.frameRate
        origins.append(Origin(sample: sample, frame: chunk.startFrame))
    }

    func fileFrame(atSample sample: Int) -> Double {
        guard let origin = origins.last(where: { $0.sample <= sample }) ?? origins.first,
              let frameRate else { return 0 }
        return Double(origin.frame) + Double(sample - origin.sample) * frameRate / 16000.0
    }
}

/// A file's speech, read block by block → the words, one speech segment at a
/// time. Shared by the meeting import (`BatchTranscriptionEngine`, which turns
/// each utterance's frames into timestamps) and `lore transcribe`
/// (`CLITranscribeService`, which joins the text). One instance per file.
///
/// The blocks only bound how much is read at once (#273). One voice detector
/// runs over the whole file and the samples short of a whole detector window
/// wait for the next block, so speech that crosses a block edge stays one
/// segment and nothing at an edge goes unread. A block that could not be
/// converted is a hole: the run before it ends there, its last partial window
/// included, and nothing is joined across it. A segment keeps
/// `SileroVAD.leadInWindows` before its detection, as the live pass does. A
/// segment is sent to the model at no more than `chunkSeconds`; speech that
/// runs longer is cut at its quietest window in the last `cutSearchSeconds`,
/// not at a fixed place. The batch and live segmenters are separate on purpose
/// (their limits differ); they share the window and lead-in constants.
final class AudioFileSpeech {
    struct Utterance: Sendable, Equatable {
        /// Where the speech was detected, in the file's frames.
        let fileFrame: Double
        /// Where the speech ends, in the file's frames.
        let endFileFrame: Double
        let text: String
        /// Each word's span in the file's frames, from the model's own timings
        /// (#269); empty when the backend gives none.
        var words: [Span] = []
    }

    /// What one read of the file gave: the utterances, how many blocks
    /// decoded, and the decoding error that stopped it early, if one did.
    struct Reading {
        var utterances: [Utterance] = []
        var blocks = 0
        /// Whatever the file's decoder threw — an I/O-boundary value, only ever reported.
        var decodeError: (any Error)?
    }

    static let chunkSeconds = 30.0
    /// Shorter than live's 1 s: a file segment is never a forced 10 s flush piece.
    static let minimumSpeechSamples = 8000
    static let maximumSegmentSamples = Int(chunkSeconds * 16000)
    static let cutSearchSeconds = 10.0
    private static let windowSize = SileroVAD.windowSize

    /// Speech being gathered. Holds whole detector windows from `start` on.
    private struct OpenSpeech {
        /// The 16 kHz sample where `samples` begins (the lead-in's start).
        var start: Int
        /// Where the detector found the speech; the utterance's timestamp.
        var detectedAt: Int
        /// The rest of a cut: goes on speaking, so no minimum length applies —
        /// only that some of it is speech.
        var continued: Bool
        var samples: [Float]
        /// One reading per window of `samples`.
        var probabilities: [Float]
    }

    private struct Segment {
        /// The sample `samples` begins at: the lead-in's start, or the cut.
        let start: Int
        let detectedAt: Int
        let end: Int
        let samples: [Float]
    }

    private let backend: any TranscriptionBackend
    private let detector: any VoiceWindowDetector
    private var frames = FileFrameMap()
    /// Samples short of a whole window, waiting for the next block.
    private var pending: [Float] = []
    /// Samples handed to the detector.
    private var read = 0
    /// Where the detector's own sample count started (it restarts after a hole).
    private var detectorOrigin = 0
    private var leadIn: [(samples: [Float], probability: Float)] = []
    private var open: OpenSpeech?
    /// While a run is ending, its last real sample: the padding after it is not the file's.
    private var runEnd: Int?

    init(backend: any TranscriptionBackend, detector: any VoiceWindowDetector) {
        self.backend = backend
        self.detector = detector
    }

    convenience init(backend: any TranscriptionBackend, vad: VadManager) {
        self.init(backend: backend, detector: SileroWindowDetector(vad: vad))
    }

    /// Every block `nextChunk` gives, then the speech still open at the end.
    /// A decoding error ends the reading and is handed back with what came
    /// before it; a model error is thrown. `onBlock` sees each block once its
    /// finished speech is transcribed.
    nonisolated(nonsending) func read(
        nextChunk: () throws -> AudioChunk?,
        onBlock: (AudioChunk) -> Void = { _ in }
    ) async throws -> Reading {
        var reading = Reading()
        while true {
            try Task.checkCancellation()
            let chunk: AudioChunk?
            do {
                chunk = try nextChunk()
            } catch {
                reading.decodeError = error
                break
            }
            guard let chunk else { break }
            reading.blocks += 1
            reading.utterances += try await utterances(in: chunk)
            onBlock(chunk)
        }
        reading.utterances += try await transcribe(endRun())
        return reading
    }

    /// The utterances that ended in or before `chunk`. Speech still going at
    /// its end waits for the next block. A block that decoded to nothing is a
    /// hole: speech before it ends there, and the detector starts over after it.
    private nonisolated(nonsending) func utterances(in chunk: AudioChunk) async throws -> [Utterance] {
        guard !chunk.samples.isEmpty else { return try await transcribe(endRun()) }
        frames.note(chunk, atSample: read + pending.count)
        pending += chunk.samples

        var segments: [Segment] = []
        var offset = 0
        while offset + Self.windowSize <= pending.count {
            try Task.checkCancellation()
            segments += try await process(Array(pending[offset..<(offset + Self.windowSize)]))
            offset += Self.windowSize
        }
        pending.removeFirst(offset)
        return try await transcribe(segments)
    }

    /// The end of a run of samples, at a hole or at the end of the file: the
    /// last partial window (padded to a whole one) and the speech still open.
    /// Nothing ends, or counts as spoken, past the last real sample; the
    /// detector starts over for whatever follows.
    private nonisolated(nonsending) func endRun() async throws -> [Segment] {
        let real = read + pending.count
        runEnd = real
        defer { runEnd = nil }
        var segments: [Segment] = []
        if !pending.isEmpty {
            let tail = pending + [Float](repeating: 0, count: Self.windowSize - pending.count)
            pending = []
            segments += try await process(tail)
        }
        if let speech = open {
            open = nil
            segments += closed(speech, end: real)
        }
        read = real
        leadIn = []
        detectorOrigin = read
        detector.reset()
        return segments.map {
            Segment(start: $0.start, detectedAt: $0.detectedAt, end: min($0.end, real), samples: $0.samples)
        }
    }

    // MARK: - Segmenting

    private nonisolated(nonsending) func process(_ window: [Float]) async throws -> [Segment] {
        let reading = try await detector.read(window)
        let windowStart = read
        read += window.count

        if var speech = open {
            open = nil  // the one reference, so the buffer grows in place
            speech.samples += window
            speech.probabilities.append(reading.probability)
            if let event = reading.event, event.kind == .speechEnd {
                let end = min(max(detectorOrigin + event.sampleIndex, speech.detectedAt), read)
                return closed(speech, end: end)
            }
            if speech.samples.count + Self.windowSize > Self.maximumSegmentSamples {
                let (segment, rest) = Self.cut(speech)
                open = rest  // may be empty: the detector is still in speech
                return [segment]
            }
            open = speech
            return []
        }

        guard reading.event?.kind == .speechStart else {
            leadIn.append((window, reading.probability))
            if leadIn.count > SileroVAD.leadInWindows { leadIn.removeFirst() }
            return []
        }
        open = OpenSpeech(
            start: windowStart - leadIn.count * Self.windowSize,
            detectedAt: windowStart,
            continued: false,
            samples: leadIn.flatMap(\.samples) + window,
            probabilities: leadIn.map(\.probability) + [reading.probability]
        )
        leadIn = []
        return []
    }

    /// The segment `speech` makes, if it makes one: new speech needs
    /// `minimumSpeechSamples` after its detection, the rest of a cut needs a
    /// window the detector still heard as speech, and the rest is padded with
    /// silence to the model's own minimum (0.3 s).
    private func closed(_ speech: OpenSpeech, end: Int) -> [Segment] {
        let spoken = min(speech.start + speech.samples.count, runEnd ?? .max) - speech.detectedAt
        if speech.continued {
            guard speech.probabilities.contains(where: { $0 >= SileroVAD.negativeThreshold }) else { return [] }
        } else {
            guard spoken >= Self.minimumSpeechSamples else { return [] }
        }
        let floor = ASRConstants.minimumRequiredSamples(forSampleRate: 16000)
        let padding = [Float](repeating: 0, count: max(0, floor - speech.samples.count))
        return [Segment(start: speech.start, detectedAt: speech.detectedAt, end: end, samples: speech.samples + padding)]
    }

    /// Speech that reached the model's limit: cut after its quietest window in
    /// the last `cutSearchSeconds` (the latest, on a tie), and go on from there.
    private static func cut(_ speech: OpenSpeech) -> (Segment, OpenSpeech) {
        let searched = Int(cutSearchSeconds * 16000) / windowSize
        let quietest = speech.probabilities.indices.suffix(searched).reversed()
            .min { speech.probabilities[$0] < speech.probabilities[$1] }!
        let cutAt = (quietest + 1) * windowSize
        let segment = Segment(
            start: speech.start,
            detectedAt: speech.detectedAt,
            end: speech.start + cutAt,
            samples: Array(speech.samples[..<cutAt])
        )
        let rest = OpenSpeech(
            start: speech.start + cutAt,
            detectedAt: speech.start + cutAt,
            continued: true,
            samples: Array(speech.samples[cutAt...]),
            probabilities: Array(speech.probabilities[(quietest + 1)...])
        )
        return (segment, rest)
    }

    // MARK: - Transcribing

    /// One model call per segment. Empty model output is dropped. The text is
    /// `transcribe`'s; the word timings come back from the same call and are
    /// counted from the segment's first sample, its lead-in included.
    private nonisolated(nonsending) func transcribe(_ segments: [Segment]) async throws -> [Utterance] {
        var utterances: [Utterance] = []
        for segment in segments {
            try Task.checkCancellation()
            let result = try await backend.transcribeDetailed(segment.samples, previousContext: nil)
            guard !result.text.isEmpty else { continue }
            let words = TranscribedToken.words(result.tokens).map { word in
                Span(
                    start: frames.fileFrame(atSample: segment.start + Int((word.start * 16000).rounded())),
                    end: frames.fileFrame(atSample: segment.start + Int((word.end * 16000).rounded()))
                )
            }
            utterances.append(Utterance(
                fileFrame: frames.fileFrame(atSample: segment.detectedAt),
                endFileFrame: frames.fileFrame(atSample: segment.end),
                text: result.text,
                words: words
            ))
        }
        return utterances
    }
}

// MARK: - Voice detection

/// Reads one 16 kHz window at a time and says where speech starts and ends.
/// Keeps its own state from one window to the next.
protocol VoiceWindowDetector: AnyObject {
    nonisolated(nonsending) func read(_ window: [Float]) async throws -> (event: VadStreamEvent?, probability: Float)
    /// Start over, as at the start of a file.
    func reset()
}

/// Silero, one stream state for the whole file.
final class SileroWindowDetector: VoiceWindowDetector {
    private let vad: VadManager
    private var state = VadStreamState.initial()

    init(vad: VadManager) {
        self.vad = vad
    }

    nonisolated(nonsending) func read(_ window: [Float]) async throws -> (event: VadStreamEvent?, probability: Float) {
        let result = try await vad.processStreamingChunk(
            window, state: state, config: SileroVAD.segmentation, returnSeconds: true, timeResolution: 2
        )
        state = result.state
        return (result.event, result.probability)
    }

    func reset() {
        state = .initial()
    }
}

// MARK: - AVAudioFile

/// The meeting import's reader: `AVAudioFile`, resampled here block by block
/// through one converter for the whole file, so the resampler's filter runs
/// on across block edges instead of against silence at each (#273). The
/// converter can hold part of a block's output until the next block, so a
/// chunk's `startFrame` is where its first sample falls, counted from what
/// the converter has put out. The last block carries what it still held. A
/// block the converter fails on comes back empty — a hole — and the next
/// block starts a fresh converter, placed from its own position; a failed
/// converter holds nothing that could still be drained.
final class AudioFileChunkReader {
    private let file: AVAudioFile
    private var frameOffset: Int64 = 0
    private var converter: AVAudioConverter?
    /// Where the converter began, and the 16 kHz samples it has put out since.
    private var converterStart: Int64 = 0
    private var converted = 0

    init(file: AVAudioFile) {
        self.file = file
    }

    var frameRate: Double { file.processingFormat.sampleRate }

    /// The next chunk, or nil past the end. A block that could not be
    /// converted comes back empty, and the next starts a fresh converter.
    func nextChunk() throws -> AudioChunk? {
        let totalFrames = file.length
        guard frameOffset < totalFrames else { return nil }
        let chunkFrames = Int64(AudioFileSpeech.chunkSeconds * frameRate)
        let framesToRead = min(chunkFrames, totalFrames - frameOffset)
        let startFrame = converterStart + Int64((Double(converted) * frameRate / 16000).rounded())
        var samples = try readChunk(startFrame: frameOffset, frameCount: AVAudioFrameCount(framesToRead))
        frameOffset += framesToRead
        if frameOffset == totalFrames { samples += drain() }
        if samples.isEmpty {
            converter = nil
            converterStart = frameOffset
            converted = 0
        } else {
            converted += samples.count
        }
        return AudioChunk(startFrame: startFrame, frameCount: framesToRead, frameRate: frameRate, samples: samples)
    }

    /// One block of the file, resampled to 16 kHz mono Float32 through the
    /// file's converter. Empty when the converter failed on it: what it gave
    /// before failing cannot be placed, so the block is a hole.
    private func readChunk(startFrame: Int64, frameCount: AVAudioFrameCount) throws -> [Float] {
        file.framePosition = startFrame
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: readBuf)
        let samples = AudioUtils.extractSamples(readBuf, converter: &converter, source: .file) ?? []
        let format = file.processingFormat
        let converts = !(format.commonFormat == .pcmFormatFloat32 && format.sampleRate == 16000 && format.channelCount == 1)
        return converts && converter == nil ? [] : samples
    }

    /// What the converter still holds at the end of the file.
    private func drain() -> [Float] {
        guard let converter else { return [] }
        var samples: [Float] = []
        while let output = AVAudioPCMBuffer(pcmFormat: AudioUtils.targetFormat, frameCapacity: 4096),
              AudioUtils.drain(converter, into: output), output.frameLength > 0,
              let data = output.floatChannelData {
            samples += UnsafeBufferPointer(start: data[0], count: Int(output.frameLength))
        }
        return samples
    }
}

// MARK: - AVAssetReader

/// `lore transcribe`'s reader (#254): whatever AVFoundation decodes — m4a, wav,
/// mp3, caf, and the `.qta` Voice Memos writes on recent systems. The reader
/// decodes, downmixes and resamples itself, so its frames are already the
/// models' 16 kHz samples.
final class AssetChunkReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: [Float] = []
    private var consumed: Int64 = 0
    private var finished = false

    /// Nil when the file has no audio track AVFoundation can decode.
    init?(url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        self.reader = reader
        self.output = output
    }

    /// The next chunk, or nil past the end. A decoding failure is thrown only
    /// after everything decoded before it has been handed out.
    func nextChunk() throws -> AudioChunk? {
        let chunkSamples = Int(AudioFileSpeech.chunkSeconds * 16000)
        while !finished && pending.count < chunkSamples {
            guard let buffer = output.copyNextSampleBuffer() else {
                finished = true
                break
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            pending.append(contentsOf: samples)
        }
        guard !pending.isEmpty else {
            if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            return nil
        }
        let samples = Array(pending.prefix(chunkSamples))
        pending.removeFirst(samples.count)
        let chunk = AudioChunk(
            startFrame: consumed, frameCount: Int64(samples.count), frameRate: 16000, samples: samples
        )
        consumed += Int64(samples.count)
        return chunk
    }
}
