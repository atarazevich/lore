@preconcurrency import AVFoundation
import os

private let recorderLog = Logger(subsystem: "com.lore.app", category: "MeetingRecording")

/// One meeting's audio: its mic and system tracks, their timing, and its
/// batch meta (#268). Created when the meeting starts capturing, closed once
/// when it ends, then dropped.
///
/// The capture taps hold this object, not a shared recorder, so a buffer
/// can only ever reach the meeting it was captured for. After `close()` every
/// buffer is dropped: a late tail cannot reopen a track or touch another
/// meeting's files.
///
/// The tracks are the meeting's own from the first buffer (#177), and the
/// meta is written whenever the timing changes, so a killed app leaves the
/// audio and its timing where the launch sweep reads them
/// (`TranscriptHealer.sweep`).
final class MeetingRecording: @unchecked Sendable {
    /// Timestamp format for the merged m4a export filename (`<stamp>.m4a` in
    /// the notes folder). Shared with the rebuild-audio matcher in
    /// `SessionRepository.notesFolderExport` (#109) so writer and matcher
    /// can't drift.
    static let exportTimestampFormat = "yyyy-MM-dd_HH-mm"

    let sessionID: String
    /// The meeting's `audio/` directory
    /// (`SessionRepository.prepareAudioDirectory`).
    let directory: URL
    /// Names the export.
    private let startedAt = Date()

    /// The merged m4a's file name in the notes folder: `<stamp>.m4a`, from
    /// when this recording started.
    var exportName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = Self.exportTimestampFormat
        return "\(formatter.string(from: startedAt)).m4a"
    }

    /// Serial writer for `batch-meta.json`, so the newest snapshot is always
    /// the last one written.
    private let metaQueue = DispatchQueue(label: "com.lore.recording.meta", qos: .utility)
    /// At most one `recordingSaved` per recording. The file-creation failure
    /// below re-fires on every buffer; unlatched, one dead output file evicts
    /// all 2000 prior events within seconds.
    private let didRecordSaveOutcome = OSAllocatedUnfairLock(initialState: false)

    /// A track's timing: frame 0's capture date, and where each later
    /// stretch of capture begins.
    private struct Timing: Sendable {
        var start: Date?
        var stretches: [BatchMeta.TimingAnchor] = []

        /// Anchors only for a track with more than one stretch —
        /// `AnchorClock` reads anchors only from two on, the first frame 0.
        var anchors: [BatchMeta.TimingAnchor] {
            guard let start, !stretches.isEmpty else { return [] }
            return [.init(frame: 0, date: start)] + stretches
        }
    }

    /// One track. Every write runs on its own serial queue, so neither a long
    /// fill nor disk latency ever sits on the capture consumer's path — the
    /// live transcriber reads the same stream — and one track never waits
    /// for the other.
    private final class Track: @unchecked Sendable {
        let url: URL
        let name: DiagEvent.RecordingTrack
        let queue: DispatchQueue
        // Confined to `queue`.
        var file: AVAudioFile?
        var isClosed = false
        /// The current stretch's reference: a capture instant on the
        /// continuous host clock and the file frame it landed at.
        var reference: (host: TimeInterval, frame: Int64)?
        var reportedUnstamped = false
        /// Written on `queue`; read by the meta snapshot from either queue.
        let timing = OSAllocatedUnfairLock(initialState: Timing())

        init(url: URL, name: DiagEvent.RecordingTrack) {
            self.url = url
            self.name = name
            queue = DispatchQueue(label: "com.lore.recording.\(name.rawValue)", qos: .userInitiated)
        }
    }
    private let mic: Track
    private let sys: Track

    init(sessionID: String, directory: URL) {
        self.sessionID = sessionID
        self.directory = directory
        mic = Track(url: BatchAudioStash.micURL(in: directory), name: .mic)
        sys = Track(url: BatchAudioStash.sysURL(in: directory), name: .system)
    }

    // MARK: - Placement: pauses (#153), outages and clock drift (#268)

    /// How far a track may sit from its capture clock before it is corrected.
    /// Capture stamps make scheduling delay invisible, so this only absorbs
    /// rounding and the device clock's slow drift.
    private static let placementTolerance: TimeInterval = 0.02
    /// A shortfall up to this is drift or a few lost buffers, eased back a
    /// few frames per buffer; beyond it the capture really went dark.
    private static let gradualLimit: TimeInterval = 0.1
    /// The longest gap written as silence. Past it a gap is not silence to
    /// reproduce: the track starts a new stretch (an anchor, #128) after one
    /// second of silence that keeps the batch pass from splicing speech
    /// across it, and the merge lays the gap out in the export.
    static let longestFill: TimeInterval = 120
    private static let stretchSeparator: TimeInterval = 1

    /// One second of silence per write call, so a fill is many small writes.
    private static let fillChunk: TimeInterval = 1.0

    /// What a buffer needs before it is written, from how far the track is
    /// from the frame the buffer's capture instant is due at (`shortfall` in
    /// frames: positive when the track is behind, negative when ahead).
    enum Correction: Equatable {
        case none
        /// Repeat the buffer's first frame this many times — a slow clock.
        case hold(AVAudioFrameCount)
        /// Drop this many frames from the buffer's front — a fast clock.
        case trim(AVAudioFrameCount)
        /// Write this much silence first — a gap in capture.
        case fill(Int64)
        /// Start a new stretch — a gap too long to write out.
        case newStretch
    }

    /// Drift is eased at most 0.5 % per buffer (at least one frame): far
    /// faster than any device clock drifts, far too little to hear.
    static func correction(shortfall: Int64, rate: Double, bufferFrames: AVAudioFrameCount) -> Correction {
        let tolerance = Int64(placementTolerance * rate)
        let step = Int64(max(1, bufferFrames / 200))
        switch shortfall {
        case (Int64(longestFill * rate) + 1)...: return .newStretch
        case (Int64(gradualLimit * rate) + 1)...: return .fill(shortfall)
        case (tolerance + 1)...: return .hold(AVAudioFrameCount(min(shortfall, step)))
        case ...(-tolerance - 1):
            // Far ahead is a jump back to capture time; slightly ahead is eased.
            let limit = shortfall < -Int64(gradualLimit * rate) ? Int64(bufferFrames) : step
            return .trim(AVAudioFrameCount(min(-shortfall, limit)))
        default: return .none
        }
    }

    private static func writeSilence(_ frames: Int64, to file: AVAudioFile) {
        let format = file.processingFormat
        guard let silence = AudioUtils.silentBuffer(
            format: format,
            frames: AVAudioFrameCount(min(frames, Int64(fillChunk * format.sampleRate)))
        ) else {
            recorderLog.error("gap fill skipped: cannot allocate buffer")
            return
        }
        var remaining = frames
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, Int64(silence.frameCapacity)))
            do {
                try file.write(from: silence)
            } catch {
                recorderLog.error("gap fill write error: \(error.localizedDescription, privacy: .private)")
                return
            }
            remaining -= Int64(silence.frameLength)
        }
    }

    // MARK: - Writing

    func writeMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        enqueue(buffer, to: mic, prepare: Self.downmix)
    }

    func writeSysBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        enqueue(buffer, to: sys) { $0 }
    }

    private func enqueue(
        _ buffer: AVAudioPCMBuffer,
        to track: Track,
        prepare: @escaping @Sendable (AVAudioPCMBuffer) -> AVAudioPCMBuffer?
    ) {
        // Buffers are never mutated after capture (the bus hands the same
        // instance to every consumer), so reading one on the track's queue
        // is safe.
        nonisolated(unsafe) let buffer = buffer
        track.queue.async { [self] in
            guard !track.isClosed, let prepared = prepare(buffer) else { return }
            write(prepared, stamp: (buffer as? CapturedBuffer)?.stamp, to: track)
        }
    }

    /// Runs on the track's queue.
    private func write(_ buffer: AVAudioPCMBuffer, stamp: CapturedBuffer.Stamp?, to track: Track) {
        if track.file == nil {
            do {
                track.file = try AVAudioFile(
                    forWriting: track.url,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
            } catch {
                recordSaveOutcomeOnce(.failed, frames: 0)
                recorderLog.error("track file creation failed: \(error.localizedDescription, privacy: .private)")
                return
            }
        }
        guard let file = track.file else { return }

        var pending: AVAudioPCMBuffer? = buffer
        var newStretch = false
        if let stamp, let reference = track.reference {
            let rate = file.processingFormat.sampleRate
            let due = reference.frame + Int64(((stamp.hostSeconds - reference.host) * rate).rounded())
            switch Self.correction(shortfall: due - file.length, rate: rate, bufferFrames: buffer.frameLength) {
            case .none:
                break
            case .hold(let frames):
                pending = CapturedBuffer.copy(of: buffer.audioBufferList, format: buffer.format, holding: frames, stamp: stamp)
            case .trim(let frames):
                pending = CapturedBuffer.copy(of: buffer.audioBufferList, format: buffer.format, dropping: frames, stamp: stamp)
            case .fill(let frames):
                Self.writeSilence(frames, to: file)
            case .newStretch:
                Self.writeSilence(Int64(Self.stretchSeparator * rate), to: file)
                newStretch = true
            }
        } else if stamp == nil, !track.reportedUnstamped {
            track.reportedUnstamped = true
            recorderLog.error("\(track.name.rawValue, privacy: .public) buffer arrived without its capture time")
            DiagStore.record(.recordingBufferUnstamped(track: track.name))
        }
        guard let pending else { return }

        let preWrite = file.length
        do {
            try file.write(from: pending)
        } catch {
            recorderLog.error("track write error: \(error.localizedDescription, privacy: .private)")
            return
        }

        // Timing changes only once the buffer is on disk; a failing write
        // leaves none behind. The reference is the first stamped buffer that
        // lands in a stretch; frame 0 and each later stretch are dated by
        // capture, not arrival.
        if let stamp, newStretch || track.reference == nil {
            track.reference = (stamp.hostSeconds, preWrite)
        }
        if let stamp, newStretch {
            track.timing.withLock { $0.stretches.append(.init(frame: preWrite, date: stamp.capturedAt)) }
            persistMeta()
            recorderLog.debug("\(track.name.rawValue, privacy: .public) track: long gap, new stretch")
        }
        if track.timing.withLock({ $0.start }) == nil {
            track.timing.withLock { $0.start = stamp?.capturedAt ?? Date() }
            persistMeta()
        }
    }

    /// Mono float copy of a mic buffer at its own rate — float32, int16 and
    /// int32, interleaved or not.
    private static func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1
        ),
        let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
        let dst = monoBuf.floatChannelData?[0] else { return nil }
        monoBuf.frameLength = buffer.frameLength

        if let src = buffer.floatChannelData {
            if channels == 1 {
    memcpy(dst, src[0], frames * MemoryLayout<Float>.size)
            } else {
                let scale = 1.0 / Float(channels)
                if buffer.format.isInterleaved {
                    for i in 0..<frames {
                        var sum: Float = 0
                        for ch in 0..<channels { sum += src[0][(i * channels) + ch] }
                        dst[i] = sum * scale
                    }
                } else {
                    for i in 0..<frames {
                        var sum: Float = 0
                        for ch in 0..<channels { sum += src[ch][i] }
                        dst[i] = sum * scale
                    }
                }
            }
        } else if let src = buffer.int16ChannelData {
            let scale = 1.0 / Float(Int16.max)
            if channels == 1 {
                for i in 0..<frames { dst[i] = Float(src[0][i]) * scale }
            } else if buffer.format.isInterleaved {
                let invCh = 1.0 / Float(channels)
                for i in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += Float(src[0][(i * channels) + ch]) * scale }
                    dst[i] = sum * invCh
                }
            } else {
                let invCh = 1.0 / Float(channels)
                for i in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += Float(src[ch][i]) * scale }
                    dst[i] = sum * invCh
                }
            }
        } else if let src = buffer.int32ChannelData {
            let scale = 1.0 / Float(Int32.max)
            if channels == 1 {
                for i in 0..<frames { dst[i] = Float(src[0][i]) * scale }
            } else if buffer.format.isInterleaved {
                let invCh = 1.0 / Float(channels)
                for i in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += Float(src[0][(i * channels) + ch]) * scale }
                    dst[i] = sum * invCh
                }
            } else {
                let invCh = 1.0 / Float(channels)
                for i in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += Float(src[ch][i]) * scale }
                    dst[i] = sum * invCh
                }
            }
        } else {
            recorderLog.error("mic write skip: unsupported buffer format \(buffer.format.commonFormat.rawValue, privacy: .public)")
            return nil
        }

        return monoBuf
    }

    // MARK: - Close and export

    /// Drain both tracks, close their files and write the final meta; every
    /// buffer that arrives afterwards is dropped. Returns the final meta —
    /// the value written to `batch-meta.json`, so the merge (which reads only
    /// this, carried in the export's marker, #290) and the batch pass (which
    /// reads the file) agree.
    ///
    /// Each track closes on its own queue, behind every buffer queued before
    /// it, so the meeting's tail lands and nothing can write after. The meta
    /// writes queued by those buffers run before the final one, and the final
    /// one is awaited: when this returns, `batch-meta.json` is complete. It is
    /// also the retry for a meta write that failed during the meeting
    /// (`BatchAudioStash.writeMeta` can only log it).
    ///
    /// A recording that captured nothing writes no meta: an empty meta beside
    /// no tracks would be a file claiming a stash. A second close changes
    /// nothing on disk.
    func close() async -> BatchMeta {
        var wasOpen = false
        for track in [mic, sys] {
            let closedNow = await withCheckedContinuation { continuation in
                track.queue.async {
                    let closedNow = !track.isClosed
                    track.isClosed = true
                    track.file = nil
                    continuation.resume(returning: closedNow)
                }
            }
            wasOpen = wasOpen || closedNow
        }
        let meta = metaSnapshot()
        let directory = directory
        let writeFinal = wasOpen && meta.hasTiming
        await withCheckedContinuation { continuation in
            metaQueue.async {
                if writeFinal { BatchAudioStash.writeMeta(meta, in: directory) }
                continuation.resume()
            }
        }
        return meta
    }

    /// How one export went.
    enum ExportResult: Equatable, Sendable {
        case written(frames: Int)
        /// Neither track has a frame to merge.
        case noAudio
        /// Not written — cancelled included.
        case failed
    }

    /// The export run here and awaited, for a meeting whose marker could not
    /// be written (#290): without one nothing keeps the tracks for the
    /// healer's export, so finalize saves the recording itself, as it did
    /// before. Fills the partial file beside the m4a and renames it into
    /// place, like the healer's export, and traces the outcome.
    func exportNow(_ meta: BatchMeta, into notesDirectory: URL) async {
        let recording = notesDirectory.appendingPathComponent(exportName)
        let partial = SessionRepository.partialExport(of: recording)
        let result = await Task.detached(priority: .userInitiated) { [directory] in
            Self.exportMerged(tracksIn: directory, meta: meta, to: partial)
        }.value
        if case .written(let frames) = result, rename(partial.path, recording.path) == 0 {
            DiagStore.record(.recordingExported(outcome: .ok, frames: frames))
        } else {
            try? FileManager.default.removeItem(at: partial)
            DiagStore.record(.recordingExported(outcome: .failed, frames: 0))
        }
    }

    // MARK: - Private

    private func metaSnapshot() -> BatchMeta {
        let micTiming = mic.timing.withLock { $0 }
        let sysTiming = sys.timing.withLock { $0 }
        return BatchMeta(
            micStartDate: micTiming.start,
            sysStartDate: sysTiming.start,
            micAnchors: micTiming.anchors,
            sysAnchors: sysTiming.anchors
        )
    }

    /// Persist the timing the moment it changes, off the audio path.
    ///
    /// It places a rebuilt transcript in real time (#128), and after a kill
    /// there is no in-memory state left to write it from — a recovered
    /// recording without it is stamped at the moment of the rebuild rather
    /// than the moment it was spoken.
    private func persistMeta() {
        let meta = metaSnapshot()
        let directory = directory
        metaQueue.async { BatchAudioStash.writeMeta(meta, in: directory) }
    }

    /// One track laid out on the export's timeline: runs of its samples, each
    /// at its own output position. The time between runs — a gap too long to
    /// have been written as silence — costs nothing until it is mixed.
    private struct Layout {
        var samples: [Float] = []
        var runs: [(at: Int, from: Int, count: Int)] = []
        var end: Int { runs.last.map { $0.at + $0.count } ?? 0 }

        /// Each stretch begins where `AnchorClock` — the batch pass's own
        /// reader of the meta — dates its first frame, after `origin`; a run
        /// that would overlap the one before starts where that one ends.
        init(
            samples: [Float], start: Date?, anchors: [BatchMeta.TimingAnchor], trackRate: Double,
            origin: Date?, outputRate: Double
        ) {
            self.samples = samples
            guard let start, let origin else {
                runs = [(0, 0, samples.count)]
                return
            }
            let clock = AnchorClock(startDate: start, sampleRate: trackRate, anchors: anchors)
            let bounds = clock.anchors.count >= 2 ? clock.anchors.map(\.frame) : [0]
            let toOutput = outputRate / trackRate
            let count = samples.count
            func index(_ frame: Int64) -> Int {
                min(count, Int((Double(frame) * toOutput).rounded()))
            }
            for (i, frame) in bounds.enumerated() {
                let from = index(frame)
                let to = i + 1 < bounds.count ? index(bounds[i + 1]) : count
                guard from < to else { continue }
                let date = clock.date(atFrame: Double(frame))
                let due = Int((date.timeIntervalSince(origin) * outputRate).rounded())
                runs.append((max(end, due), from, to - from))
            }
        }

        /// Add this track's samples for `range` of the timeline into `out`.
        func mix(into out: UnsafeMutablePointer<Float>, range: Range<Int>) {
            for run in runs {
                let lower = max(range.lowerBound, run.at)
                let upper = min(range.upperBound, run.at + run.count)
                guard lower < upper else { continue }
                for j in lower..<upper {
                    out[j - range.lowerBound] += samples[run.from + j - run.at]
                }
            }
        }
    }

    /// Merge a closed meeting's tracks, in `tracks`, into an m4a at `file`,
    /// placed by `meta` — the meta `close()` returned. The healer's export
    /// job runs it (#290) from the meeting's marker, so it needs no
    /// recording, and a later launch can run it again. Checks for
    /// cancellation between chunks, reading each track and writing the mix;
    /// a file cut short, by a cancellation or a failed write, is the caller's
    /// to remove.
    static func exportMerged(tracksIn tracks: URL, meta: BatchMeta, to file: URL) -> ExportResult {
        func reader(_ url: URL) -> AVAudioFile? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? AVAudioFile(forReading: url)
        }
        let micReader = reader(BatchAudioStash.micURL(in: tracks))
        let sysReader = reader(BatchAudioStash.sysURL(in: tracks))

        guard micReader != nil || sysReader != nil else {
            recorderLog.error("no audio data recorded")
            return .noAudio
        }

        let targetRate: Double = 48_000
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1) else {
            return .failed
        }

        // Both tracks on one timeline from the earlier one's frame 0: each
        // stretch at its own date, so the export agrees with the batch
        // transcript's `AnchorClock` (#268).
        let origin = [meta.micStartDate, meta.sysStartDate].compactMap { $0 }.min()
        func layout(_ file: AVAudioFile?, _ start: Date?, _ anchors: [BatchMeta.TimingAnchor]) -> Layout {
            Layout(
                samples: readAllMono(file: file, targetRate: targetRate, targetFormat: targetFormat),
                start: start, anchors: anchors,
                trackRate: file?.processingFormat.sampleRate ?? targetRate,
                origin: origin, outputRate: targetRate
            )
        }
        let micLayout = layout(micReader, meta.micStartDate, meta.micAnchors)
        guard !Task.isCancelled else { return .failed }
        let tracks = [micLayout, layout(sysReader, meta.sysStartDate, meta.sysAnchors)]
        guard !Task.isCancelled else { return .failed }

        let length = tracks.map(\.end).max() ?? 0
        guard length > 0 else { return .noAudio }

        // #148: created at first use, not at launch.
        NotesFolder.prepare(file.deletingLastPathComponent())

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: file,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: targetRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            recorderLog.error("failed to create output file: \(error.localizedDescription, privacy: .private)")
            return .failed
        }
        defer { outputFile.close() }

        // Write mixed audio in chunks
        let chunkSize = 65_536
        var offset = 0
        while offset < length {
            guard !Task.isCancelled else { return .failed }
            let count = min(chunkSize, length - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(count)),
                  let out = buffer.floatChannelData?[0] else { return .failed }
            buffer.frameLength = AVAudioFrameCount(count)
            out.initialize(repeating: 0, count: count)
            for track in tracks {
                track.mix(into: out, range: offset..<(offset + count))
            }
            for i in 0..<count {
                out[i] = max(-1, min(1, out[i]))
            }

            do {
                try outputFile.write(from: buffer)
            } catch {
                recorderLog.error("export write error: \(error.localizedDescription, privacy: .private)")
                return .failed
            }
            offset += count
        }
        return .written(frames: length)
    }

    /// A whole track as mono samples at `targetRate`, read and converted a
    /// chunk at a time. A cancelled export (#290) stops at the next chunk
    /// with what it has read, which its caller discards; a read error gives
    /// nothing, as it always has.
    private static func readAllMono(
        file: AVAudioFile?,
        targetRate: Double,
        targetFormat: AVAudioFormat
    ) -> [Float] {
        guard let file, file.length > 0 else { return [] }

        let srcFormat = file.processingFormat
        let chunk: AVAudioFrameCount = 65_536
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunk) else { return [] }
        let ratio = targetRate / srcFormat.sampleRate
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio) + 1)

        var readFailed = false
        /// The next chunk into `readBuf`; false at the end or on a read error.
        func readChunk() -> Bool {
            guard file.framePosition < file.length else { return false }
            do { try file.read(into: readBuf, frameCount: chunk) } catch {
                readFailed = true
                return false
            }
            return readBuf.frameLength > 0
        }

        // Resample and/or downmix via AVAudioConverter — unless already at
        // the target format, or no converter can be made.
        let direct = srcFormat.sampleRate == targetRate && srcFormat.channelCount == 1
        guard !direct, let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            while !Task.isCancelled, readChunk() {
                samples += direct ? extractSamples(from: readBuf) : extractMonoSamples(from: readBuf)
            }
            return readFailed ? [] : samples
        }
        converter.downmix = true  // average every channel, not only the first (#271)

        let outFrames = AVAudioFrameCount(Double(chunk) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return [] }
        while !Task.isCancelled {
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, inputStatus in
                guard readChunk() else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return readBuf
            }
            samples += extractSamples(from: outBuf)
            guard status == .haveData else { break }
        }
        return readFailed ? [] : samples
    }

    private static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: count))
    }

    private static func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData else { return [] }
        let channels = Int(buffer.format.channelCount)
        if channels <= 1 { return extractSamples(from: buffer) }

        let scale = 1.0 / Float(channels)
        return (0..<count).map { i in
            var sum: Float = 0
            for ch in 0..<channels { sum += data[ch][i] }
            return sum * scale
        }
    }

    /// Record the recording's save outcome at most once. Callers on the
    /// buffer path would otherwise emit one event per audio callback.
    private func recordSaveOutcomeOnce(_ outcome: DiagEvent.Outcome, frames: Int) {
        let shouldRecord = didRecordSaveOutcome.withLock { recorded in
            defer { recorded = true }
            return !recorded
        }
        guard shouldRecord else { return }
        DiagStore.record(.recordingSaved(outcome: outcome, frames: frames))
    }
}
