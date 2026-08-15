@preconcurrency import AVFoundation
import os

private let recorderLog = Logger(subsystem: "com.lore.app", category: "AudioRecorder")

/// Records mic and system audio into the meeting's own `audio/` directory as
/// two CAF tracks, then merges and encodes them into a single M4A (AAC) file
/// on finalization.
///
/// The tracks are the meeting's from the first buffer (#177), so a kill leaves
/// the audio where the launch sweep already reads it (`TranscriptHealer.sweep`)
/// and finalization has nothing to move.
final class AudioRecorder: @unchecked Sendable {
    /// Timestamp format for the merged m4a export filename (`<stamp>.m4a` in
    /// the notes folder). Shared with the rebuild-audio matcher in
    /// `SessionRepository.notesFolderExport` (#109) so writer and matcher
    /// can't drift.
    static let exportTimestampFormat = "yyyy-MM-dd_HH-mm"

    private let lock = NSLock()
    private var micFile: AVAudioFile?
    private var sysFile: AVAudioFile?
    /// The meeting this recorder is armed for. Every operation names its
    /// session and does nothing unless it matches, so work belonging to an
    /// earlier meeting — a finalize that outlived its timeout — can never close
    /// or export a later one's recording.
    private var armedSessionID: String?
    /// The meeting's `audio/` directory — the two tracks and their timing meta
    /// live here for as long as the recording does. Nil means disarmed: no
    /// directory, no track URLs, so a late buffer writes nothing.
    private var trackDirectory: URL?
    private var micTrackURL: URL? { trackDirectory.map(BatchAudioStash.micURL(in:)) }
    private var sysTrackURL: URL? { trackDirectory.map(BatchAudioStash.sysURL(in:)) }
    private var outputDirectory: URL
    private var sessionTimestamp = ""
    /// Off-thread writer for `batch-meta.json`. Serial, so the newest snapshot
    /// is always the last one written; `.utility` keeps the audio callback that
    /// produced an anchor free of file I/O.
    private let metaQueue = DispatchQueue(label: "com.lore.recorder.meta", qos: .utility)
    /// At most one `recordingSaved` per recording. The file-creation failures below sit
    /// inside `if micFile == nil { … } catch { … return }`, so they re-fire on EVERY
    /// audio buffer — unlatched, one dead output file evicts all 2000 prior events
    /// within seconds, which is precisely the history the ring exists to keep.
    ///
    /// Its own lock, not `lock`: the buffer-path callers already hold `lock` (recursing
    /// would deadlock) while the finalize-path callers hold nothing.
    private let saveOutcomeLock = NSLock()
    private var didRecordSaveOutcome = false

    /// Wall-clock timestamp of the first buffer write for each stream.
    private var micStartDate: Date?
    private var sysStartDate: Date?

    /// Wall-clock timestamp and frame position of the most recent buffer write.
    /// In memory only, unlike the anchors below: it feeds the
    /// effective-sample-rate correction in `mergeAndEncode`, which serves the
    /// merged export a killed meeting never produces.
    private var sysEndDate: Date?
    private var sysEndFrame: Int64 = 0

    /// Same for the mic track — used only for capture-gap detection (#128);
    /// the sys pair above doubles for effective-sample-rate computation.
    private var micEndDate: Date?
    private var micEndFrame: Int64 = 0

    /// Timing anchors mapping frame positions to wall-clock dates.
    private(set) var micAnchors: [(frame: Int64, date: Date)] = []
    private(set) var sysAnchors: [(frame: Int64, date: Date)] = []

    /// A pause is over and this track has not yet filled its gap (#153). The
    /// only pause state the recorder keeps — the gap's *length* is never
    /// stored, it is derived at write time from the track's own last-write
    /// date.
    private var micNeedsPauseFill = false
    private var sysNeedsPauseFill = false

    /// A capture outage appends no silence: wall time advances while file
    /// frames don't. True when the wall-clock delta since the last write
    /// exceeds the audio duration written since then by more than the
    /// threshold — capture went dark and resumed, so a fresh anchor is due (#128).
    private static let captureGapThreshold: TimeInterval = 2.0

    static func isCaptureGap(
        frameDelta: Int64,
        sampleRate: Double,
        wallDelta: TimeInterval
    ) -> Bool {
        guard sampleRate > 0 else { return false }
        return wallDelta - Double(frameDelta) / sampleRate > captureGapThreshold
    }

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    func updateDirectory(_ url: URL) {
        lock.withLock { outputDirectory = url }
    }

    /// Arm the recorder for one meeting: its id, and its own `audio/` directory
    /// (`SessionRepository.prepareAudioDirectory`).
    ///
    /// Re-arming the same meeting keeps the running recording: the destination
    /// is fixed per meeting, so a second arm would re-create `mic.caf` for
    /// writing and truncate everything recorded so far
    /// (`confirmDownloadAndStart` is the one path that can reach here twice,
    /// #153).
    func startSession(id sessionID: String, trackDirectory directory: URL) {
        guard lock.withLock({ armedSessionID != sessionID }) else {
            recorderLog.debug("recorder already armed for this meeting — keeping the running tracks")
            return
        }
        saveOutcomeLock.withLock { didRecordSaveOutcome = false }
        lock.withLock {
            micFile = nil
            sysFile = nil
            micStartDate = nil
            sysStartDate = nil
            sysEndDate = nil
            sysEndFrame = 0
            micEndDate = nil
            micEndFrame = 0
            micAnchors = []
            sysAnchors = []
            micNeedsPauseFill = false
            sysNeedsPauseFill = false

            let fmt = DateFormatter()
            fmt.dateFormat = Self.exportTimestampFormat
            sessionTimestamp = fmt.string(from: Date())

            armedSessionID = sessionID
            trackDirectory = directory
        }
    }

    // MARK: - Pause / Resume (#153)

    /// Capture is coming back after a user pause: each track fills its own gap
    /// with silence on its next write.
    ///
    /// Nothing about *when* the pause started or how long it ran is recorded.
    /// Each gap is derived at write time from that track's own last-write date,
    /// which buys three things a stored duration cannot: it is frame-exact per
    /// track (the two legs come back at different instants), it self-heals (a
    /// failed fill leaves the date untouched, so the next buffer retries), and
    /// it needs no accounting when a resume fails or a second pause follows —
    /// whenever audio lands, the gap it measures is the whole span since real
    /// audio last did. A kill during a pause needs no accounting either: a gap
    /// only misplaces the audio that follows it, and after a kill there is
    /// none. Why the gap must be filled at all:
    /// `docs/features/meeting-pause-resume.md`.
    func noteResumedFromPause() {
        lock.withLock {
            micNeedsPauseFill = true
            sysNeedsPauseFill = true
        }
    }

    /// One second of silence per write call. Bounds both the buffer allocation
    /// and each individual `write`, so a long pause is filled by many small
    /// writes instead of one multi-hundred-megabyte one.
    private static let pauseFillChunk: TimeInterval = 1.0

    /// Fill one track's pause gap with silence. Caller holds `lock`; returns
    /// whether the fill is finished (and the pending flag can be cleared).
    ///
    /// A track with no audio yet — `lastWrite` nil — has nothing to stay
    /// aligned with, and its own first-write date is already the truth, so
    /// nothing is written and the gap is considered closed. Leading silence
    /// there would push the whole track late by the pause.
    private static func fillPauseGap(
        in file: AVAudioFile?,
        lastWrite: Date?,
        now: Date
    ) -> Bool {
        guard let file, let lastWrite else { return true }

        let format = file.processingFormat
        let gap = now.timeIntervalSince(lastWrite)
        var remaining = Int64(gap * format.sampleRate)
        guard remaining > 0 else { return true }

        let chunkFrames = AVAudioFrameCount(pauseFillChunk * format.sampleRate)
        guard let silence = AudioUtils.silentBuffer(
            format: format,
            frames: AVAudioFrameCount(min(remaining, Int64(chunkFrames)))
        ) else {
            recorderLog.error("pause fill skipped: cannot allocate buffer")
            return true
        }

        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, Int64(silence.frameCapacity)))
            do {
                try file.write(from: silence)
            } catch {
                // Retried on the next buffer against an unchanged last-write
                // date, so nothing is lost by giving up here.
                recorderLog.error("pause fill write error: \(error.localizedDescription, privacy: .private)")
                return false
            }
            remaining -= Int64(silence.frameLength)
        }
        recorderLog.debug("filled \(gap, privacy: .public)s of pause with silence")
        return true
    }

    func writeMicBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard buffer.frameLength > 0 else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)

            // Lazily create file as mono at the source sample rate
            if micFile == nil, let url = micTrackURL {
                guard let monoFormat = AVAudioFormat(
                    standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1
                ) else {
                    recorderLog.error("mic file skip: cannot create mono format at \(buffer.format.sampleRate, privacy: .public)Hz")
                    return
                }
                do {
                    micFile = try AVAudioFile(forWriting: url, settings: monoFormat.settings)
                    recorderLog.debug("mic file created mono at \(buffer.format.sampleRate, privacy: .public)Hz")
                } catch {
                    recordSaveOutcomeOnce(.failed, frames: 0)
                    recorderLog.error("mic file creation failed: \(error.localizedDescription, privacy: .private)")
                    return
                }
            }

            let now = Date()

            // Before `preWriteFrame` is read, so the frame delta below spans
            // the fill too and the pause reads as continuous audio rather than
            // a capture gap needing a new anchor (#153/#128).
            if micNeedsPauseFill {
                micNeedsPauseFill = !Self.fillPauseGap(in: micFile, lastWrite: micEndDate, now: now)
            }

            // Downmix to mono inline — handle float32, int16, and int32 formats
            guard let monoFormat = AVAudioFormat(
                standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1
            ),
            let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
            let dst = monoBuf.floatChannelData?[0] else { return }
            monoBuf.frameLength = buffer.frameLength

            if let src = buffer.floatChannelData {
                if channels == 1 {
                    if buffer.format.isInterleaved {
                        memcpy(dst, src[0], frames * MemoryLayout<Float>.size)
                    } else {
                        memcpy(dst, src[0], frames * MemoryLayout<Float>.size)
                    }
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
                return
            }

            let preWriteFrame = micFile?.length ?? 0
            do {
                try micFile?.write(from: monoBuf)
            } catch {
                recorderLog.error("mic write error: \(error.localizedDescription, privacy: .private)")
                return
            }

            // Timing anchor on first successful write, and again whenever
            // capture resumes after an outage (#128). Tracking advances only
            // on success — a failing write leaves state at the last audio
            // that actually landed, so persistent failure can't spam anchors
            // or skew the frame delta.
            if micStartDate == nil {
                micStartDate = now
                micAnchors.append((frame: preWriteFrame, date: now))
                persistMetaLocked()
            } else if let last = micEndDate, let file = micFile,
                      Self.isCaptureGap(
                          frameDelta: preWriteFrame - micEndFrame,
                          sampleRate: file.processingFormat.sampleRate,
                          wallDelta: now.timeIntervalSince(last)
                      ) {
                micAnchors.append((frame: preWriteFrame, date: now))
                persistMetaLocked()
            }
            micEndDate = now
            micEndFrame = micFile?.length ?? preWriteFrame
        }
    }

    func writeSysBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard buffer.frameLength > 0 else { return }
            if sysFile == nil, let url = sysTrackURL {
                do {
                    sysFile = try AVAudioFile(
                        forWriting: url,
                        settings: buffer.format.settings,
                        commonFormat: buffer.format.commonFormat,
                        interleaved: buffer.format.isInterleaved
                    )
                } catch {
                    recordSaveOutcomeOnce(.failed, frames: 0)
                    recorderLog.error("sys file creation failed: \(error.localizedDescription, privacy: .private)")
                    return
                }
            }

            let now = Date()

            // Same as the mic track, and load-bearing here: `sysEndFrame` feeds
            // the effective-sample-rate correction in `mergeAndEncode` (#153).
            if sysNeedsPauseFill {
                sysNeedsPauseFill = !Self.fillPauseGap(in: sysFile, lastWrite: sysEndDate, now: now)
            }

            let preWriteFrame = sysFile?.length ?? 0
            do {
                try sysFile?.write(from: buffer)
            } catch {
                recorderLog.error("sys write error: \(error.localizedDescription, privacy: .private)")
                return
            }

            // Timing anchor on first successful write, and again whenever
            // capture resumes after an outage (#128). Tracking advances only
            // on success; the end date/frame also feed the effective-sample-
            // rate computation in mergeAndEncode, which wants actually-written
            // audio — the post-write file length gives both consumers that.
            if sysStartDate == nil {
                sysStartDate = now
                sysAnchors.append((frame: preWriteFrame, date: now))
                persistMetaLocked()
            } else if let last = sysEndDate, let file = sysFile,
                      Self.isCaptureGap(
                          frameDelta: preWriteFrame - sysEndFrame,
                          sampleRate: file.processingFormat.sampleRate,
                          wallDelta: now.timeIntervalSince(last)
                      ) {
                sysAnchors.append((frame: preWriteFrame, date: now))
                persistMetaLocked()
            }
            sysEndDate = now
            sysEndFrame = sysFile?.length ?? preWriteFrame
        }
    }

    /// Close `sessionID`'s tracks, let go of the meeting, and return once the
    /// queued meta writes have landed — the batch pass may read the meta the
    /// moment finalization returns. Nothing happens when the recorder is armed
    /// for a different meeting: a finalize dropped by its timeout can reach
    /// here after a later meeting armed the recorder, and closing that one
    /// would stop a running recording dead.
    ///
    /// The tracks themselves stay inside the meeting; deleting them is the
    /// session's decision, made by session id
    /// (`SessionRepository.cleanupBatchAudio`), never by this recorder's memory
    /// of the last thing it recorded.
    ///
    /// The last anchor snapshot is written once more here. Every anchor already
    /// persisted itself as it appeared, so this changes nothing when those
    /// writes succeeded — and when one failed (`BatchAudioStash.writeMeta` can
    /// only log it) it is the meeting's one retry, without which the stash
    /// would keep its tracks and permanently lack the timing a rebuild needs.
    func finishTracks(for sessionID: String) async {
        let pending: (meta: BatchMeta, directory: URL)? = lock.withLock {
            guard armedSessionID == sessionID, let directory = trackDirectory else { return nil }
            let meta = metaSnapshotLocked()
            closeTracksLocked()
            // A meeting that recorded nothing has no timing to persist, and an
            // empty meta beside no tracks would be a file claiming a stash.
            return meta.hasAnchors ? (meta: meta, directory: directory) : nil
        }
        // Drained rather than blocked — the caller is the @MainActor finalize
        // path — and the queue is serial, so this lands after every anchor.
        await withCheckedContinuation { continuation in
            metaQueue.async {
                if let pending { BatchAudioStash.writeMeta(pending.meta, in: pending.directory) }
                continuation.resume()
            }
        }
    }

    /// Merge `sessionID`'s two tracks into the notes folder's m4a export. The
    /// track files stay on disk; the recorder lets go of them. Nothing happens
    /// when the recorder is armed for a different meeting — see
    /// `finishTracks(for:)`.
    func exportMerged(for sessionID: String) async {
        await Task.detached(priority: .userInitiated) { [self] in
            self.mergeAndEncode(for: sessionID)
        }.value
    }

    // MARK: - Private

    /// Close the two track files and let go of the meeting. Caller holds `lock`.
    ///
    /// Always both halves: a closed file with the directory still armed lets
    /// the next buffer re-create `mic.caf` forWriting — truncating the
    /// meeting's own audio.
    private func closeTracksLocked() {
        micFile = nil
        sysFile = nil
        trackDirectory = nil
        armedSessionID = nil
    }

    /// Caller holds `lock`.
    private func metaSnapshotLocked() -> BatchMeta {
        BatchMeta(
            micStartDate: micStartDate,
            sysStartDate: sysStartDate,
            micAnchors: micAnchors.map { .init(frame: $0.frame, date: $0.date) },
            sysAnchors: sysAnchors.map { .init(frame: $0.frame, date: $0.date) }
        )
    }

    /// Persist the timing anchors the moment they are created, off the audio
    /// thread. Caller holds `lock`.
    ///
    /// Anchors place a rebuilt transcript in real time (#128), and after a kill
    /// there is no in-memory state left to write them from — a recovered
    /// recording without them is stamped at the moment of the rebuild rather
    /// than the moment it was spoken. They appear at each track's first buffer
    /// and at each capture outage: a few hundred bytes, a handful of times per
    /// meeting.
    private func persistMetaLocked() {
        guard let directory = trackDirectory else { return }
        let meta = metaSnapshotLocked()
        metaQueue.async { BatchAudioStash.writeMeta(meta, in: directory) }
    }

    private func mergeAndEncode(for sessionID: String) {
        typealias ExportPlan = (
            mic: URL?, sys: URL?, dir: URL, timestamp: String, sysEffectiveRate: Double?
        )
        let plan: ExportPlan? = lock.withLock {
            // Another meeting's tracks are not this finalize's to merge, and
            // the close below would end its recording.
            guard armedSessionID == sessionID else { return nil }

            // Reading a track still open for writing would merge without its
            // unflushed tail; closing here makes the export safe in any order.
            let tracks = (mic: micTrackURL, sys: sysTrackURL)
            closeTracksLocked()

            // Effective sample rate: corrects for process tap delivering at lower rate than declared.
            var effectiveRate: Double? = nil
            if let start = sysStartDate, let end = sysEndDate, sysEndFrame > 0 {
                let wallClockSeconds = end.timeIntervalSince(start)
                if wallClockSeconds > 1.0 {
                    effectiveRate = Double(sysEndFrame) / wallClockSeconds
                }
            }
            return (tracks.mic, tracks.sys, outputDirectory, sessionTimestamp, effectiveRate)
        }
        guard let (micURL, sysURL, dir, timestamp, sysEffectiveRate) = plan else {
            recorderLog.debug("export skipped: the recorder is not armed for this meeting")
            return
        }

        let micReader: AVAudioFile? = {
            guard let url = micURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? AVAudioFile(forReading: url)
        }()
        let sysReader: AVAudioFile? = {
            guard let url = sysURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? AVAudioFile(forReading: url)
        }()

        guard micReader != nil || sysReader != nil else {
            recordSaveOutcomeOnce(.failed, frames: 0)
            recorderLog.error("no audio data recorded")
            return
        }

        let targetRate: Double = 48_000
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1) else { return }

        if let mic = micReader {
            recorderLog.debug("mic temp: \(mic.length, privacy: .public) frames")
        }
        if let sys = sysReader {
            recorderLog.debug("sys temp: \(sys.length, privacy: .public) frames")
            if let eff = sysEffectiveRate {
                recorderLog.debug("sys effective sample rate: \(eff, privacy: .public) Hz (declared \(sys.processingFormat.sampleRate, privacy: .public) Hz)")
            }
        }

        let micSamples = Self.readAllMono(file: micReader, targetRate: targetRate, targetFormat: targetFormat)

        let sysSamples: [Float]
        if let sysReader,
           let effectiveRate = sysEffectiveRate,
           abs(effectiveRate - sysReader.processingFormat.sampleRate) > 1000
        {
            recorderLog.debug("sys rate mismatch: effective=\(effectiveRate, privacy: .public) vs declared=\(sysReader.processingFormat.sampleRate, privacy: .public), resampling")
            sysSamples = Self.readAllMono(
                file: sysReader,
                targetRate: targetRate,
                targetFormat: targetFormat,
                overrideSampleRate: effectiveRate
            )
        } else {
            sysSamples = Self.readAllMono(file: sysReader, targetRate: targetRate, targetFormat: targetFormat)
        }

        let micPeak = micSamples.reduce(Float(0)) { max($0, abs($1)) }
        let sysPeak = sysSamples.reduce(Float(0)) { max($0, abs($1)) }
        recorderLog.debug("after readAllMono: micSamples=\(micSamples.count, privacy: .public) micPeak=\(micPeak, privacy: .public) sysSamples=\(sysSamples.count, privacy: .public) sysPeak=\(sysPeak, privacy: .public)")

        let length = max(micSamples.count, sysSamples.count)
        guard length > 0 else { return }

        // #148: created at first use, not at launch.
        NotesFolder.prepare(dir)

        let outputURL = dir.appendingPathComponent("\(timestamp).m4a")
        guard let outputFile = try? AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: targetRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ) else {
            recordSaveOutcomeOnce(.failed, frames: 0)
            recorderLog.error("failed to create output file")
            return
        }

        // Write mixed audio in chunks
        let chunkSize = 65_536
        var offset = 0
        while offset < length {
            let count = min(chunkSize, length - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(count)),
                  let out = buffer.floatChannelData?[0] else { break }
            buffer.frameLength = AVAudioFrameCount(count)

            for i in 0..<count {
                let m: Float = offset + i < micSamples.count ? micSamples[offset + i] : 0
                let s: Float = offset + i < sysSamples.count ? sysSamples[offset + i] : 0
                out[i] = max(-1, min(1, m + s))
            }

            do { try outputFile.write(from: buffer) } catch { break }
            offset += count
        }

        recordSaveOutcomeOnce(.ok, frames: length)
    }

    private static func readAllMono(
        file: AVAudioFile?,
        targetRate: Double,
        targetFormat: AVAudioFormat,
        overrideSampleRate: Double? = nil
    ) -> [Float] {
        guard let file, file.length > 0 else { return [] }

        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return [] }
        do { try file.read(into: readBuf) } catch { return [] }

        // Already at target format — extract directly
        if overrideSampleRate == nil && srcFormat.sampleRate == targetRate && srcFormat.channelCount == 1 {
            return extractSamples(from: readBuf)
        }

        // Re-tag the buffer at the effective rate so AVAudioConverter resamples correctly.
        let converterInput: AVAudioPCMBuffer
        let converterSrcFormat: AVAudioFormat
        if let override = overrideSampleRate, override != srcFormat.sampleRate {
            guard let retaggedFormat = AVAudioFormat(
                commonFormat: srcFormat.commonFormat,
                sampleRate: override,
                channels: srcFormat.channelCount,
                interleaved: srcFormat.isInterleaved
            ) else {
                return extractMonoSamples(from: readBuf)
            }
            guard let retaggedBuf = AVAudioPCMBuffer(
                pcmFormat: retaggedFormat,
                frameCapacity: frameCount
            ) else {
                return extractMonoSamples(from: readBuf)
            }
            retaggedBuf.frameLength = readBuf.frameLength
            if let src = readBuf.floatChannelData, let dst = retaggedBuf.floatChannelData {
                for ch in 0..<Int(srcFormat.channelCount) {
                    memcpy(dst[ch], src[ch], Int(frameCount) * MemoryLayout<Float>.size)
                }
            }
            converterInput = retaggedBuf
            converterSrcFormat = retaggedFormat
        } else {
            converterInput = readBuf
            converterSrcFormat = srcFormat
        }

        // Resample and/or downmix via AVAudioConverter
        guard let converter = AVAudioConverter(from: converterSrcFormat, to: targetFormat) else {
            return extractMonoSamples(from: converterInput)
        }

        let ratio = targetRate / converterSrcFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(frameCount) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return [] }

        var consumed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return converterInput
        }

        return extractSamples(from: outBuf)
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

    /// Record the recording's save outcome at most once per session. Callers on the
    /// buffer path would otherwise emit one event per audio callback.
    private func recordSaveOutcomeOnce(_ outcome: DiagEvent.Outcome, frames: Int) {
        let shouldRecord = saveOutcomeLock.withLock { () -> Bool in
            guard !didRecordSaveOutcome else { return false }
            didRecordSaveOutcome = true
            return true
        }
        guard shouldRecord else { return }
        DiagStore.record(.recordingSaved(outcome: outcome, frames: frames))
    }

}
