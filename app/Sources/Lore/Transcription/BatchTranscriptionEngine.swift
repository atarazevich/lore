@preconcurrency import AVFoundation
import FluidAudio
import os

private let batchLog = Logger(subsystem: "com.lore.app", category: "BatchTranscription")

/// Maps a file frame position to wall-clock time using the timing anchors
/// persisted in batch-meta.json (#128). A capture outage produces no silence
/// padding — frames are appended contiguously — so pure `start + frame/rate`
/// math drags every post-gap utterance earlier by the outage length. With two
/// or more anchors the mapping is piecewise: each frame is based on the
/// nearest anchor at-or-before it. With fewer anchors (legacy batch-meta.json)
/// it reduces exactly to the start-date math.
struct AnchorClock {
    let startDate: Date
    let sampleRate: Double
    let anchors: [BatchMeta.TimingAnchor]

    init(startDate: Date, sampleRate: Double, anchors: [BatchMeta.TimingAnchor]) {
        self.startDate = startDate
        self.sampleRate = sampleRate
        self.anchors = anchors.sorted { $0.frame < $1.frame }
    }

    /// Wall-clock date for a frame position in the file's sample-rate domain.
    func date(atFrame frame: Double) -> Date {
        guard anchors.count >= 2 else {
            return startDate.addingTimeInterval(frame / sampleRate)
        }
        let base = anchors.last(where: { Double($0.frame) <= frame }) ?? anchors[0]
        return base.date.addingTimeInterval((frame - Double(base.frame)) / sampleRate)
    }
}

/// Offline two-pass transcription engine that re-processes recorded CAF files
/// after a meeting ends — same model, full-context re-pass.
actor BatchTranscriptionEngine {

    enum Status: Sendable, Equatable {
        case idle
        case loading(sessionID: String)
        case transcribing(progress: Double, sessionID: String)
        case completed(sessionID: String)
        case cancelled
        case failed(String, sessionID: String)

        /// Session the engine is/was working on, when the state names one.
        var sessionID: String? {
            switch self {
            case .idle, .cancelled: return nil
            case .loading(let id), .transcribing(_, let id),
                 .completed(let id), .failed(_, let id):
                return id
            }
        }
    }

    private(set) var status: Status = .idle
    /// True when the current batch job is an audio file import (affects UI copy).
    private(set) var isImporting: Bool = false
    private var currentTask: Task<Void, Never>?

    /// Process batch transcription for a completed session.
    func process(
        sessionID: String,
        sessionRepository: SessionRepository,
        notesDirectory: URL
    ) async {
        // Cancel any existing task
        currentTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runTranscription(
                    sessionID: sessionID,
                    sessionRepository: sessionRepository,
                    notesDirectory: notesDirectory
                )
            } catch is CancellationError {
                await self.setStatus(.cancelled)
                batchLog.info("Batch transcription cancelled for \(sessionID)")
            } catch {
                await self.setStatus(.failed(error.localizedDescription, sessionID: sessionID))
                batchLog.error("Batch transcription failed: \(error.localizedDescription)")
            }
        }
        currentTask = task
        await task.value
    }

    /// Cancellation leaves the engine idle (#166): the failed banner this
    /// used to preserve a status for is gone, and `TranscriptHealer` — the
    /// only canceller — re-queues a preempted job from its own bookkeeping,
    /// never from a stored engine claim.
    func cancel() async {
        let task = currentTask
        currentTask = nil
        task?.cancel()
        await task?.value
        status = .idle
        isImporting = false
    }

    /// The healer read a terminal status and owns its consequences from
    /// here — return to idle so no stale claim outlives the job (#166,
    /// no-false-positives: live, not latched).
    func acknowledgeCompletion() {
        switch status {
        case .completed, .failed, .cancelled:
            status = .idle
            isImporting = false
        case .idle, .loading, .transcribing:
            break
        }
    }

    // MARK: - Audio Import

    /// Import and transcribe an external audio file (meeting recording).
    /// `startDate` anchors the record timestamps; nil falls back to the
    /// file's creation date. A rebuild of a live session over its m4a export
    /// (#109) passes the session's real start — the export is written at
    /// meeting END, so its file date would shift every timestamp.
    func importFile(
        url: URL,
        sessionID: String,
        sessionRepository: SessionRepository,
        startDate: Date? = nil
    ) async {
        currentTask?.cancel()
        isImporting = true

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runImport(
                    url: url,
                    sessionID: sessionID,
                    sessionRepository: sessionRepository,
                    startDate: startDate
                )
            } catch is CancellationError {
                // The only canceller is a recording start preempting the
                // engine. Preemption is not failure (#166): the healer
                // re-queues the job itself, so this lands as .cancelled.
                await self.setStatus(.cancelled)
                await self.setIsImporting(false)
                batchLog.info("Audio import preempted for \(sessionID)")
            } catch {
                await self.setStatus(.failed(error.localizedDescription, sessionID: sessionID))
                await self.setIsImporting(false)
                batchLog.error("Audio import failed: \(error.localizedDescription)")
            }
        }
        currentTask = task
        await task.value
    }

    private func runImport(
        url: URL,
        sessionID: String,
        sessionRepository: SessionRepository,
        startDate anchorDate: Date?
    ) async throws {
        batchLog.info("Starting audio import for \(sessionID) from \(url.lastPathComponent)")
        status = .loading(sessionID: sessionID)

        // Copy the original audio into the session up front (#43): a failed
        // run then keeps the audio for retry and playback. On retry the
        // source already IS the session copy — an explicit no-op there.
        await sessionRepository.copyAudioFileToSession(sessionID: sessionID, sourceURL: url)

        // Prepare backend and VAD
        let backend = ParakeetBackend()
        try await backend.prepare { statusMsg in
            batchLog.info("Backend: \(statusMsg)")
        }

        try Task.checkCancellation()

        let vad = try await VadManager()

        try Task.checkCancellation()

        status = .transcribing(progress: 0, sessionID: sessionID)

        // Anchor timestamps: the caller-provided start, else file attributes.
        let startDate: Date
        if let anchorDate {
            startDate = anchorDate
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let creationDate = attrs[.creationDate] as? Date {
            startDate = creationDate
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modDate = attrs[.modificationDate] as? Date {
            startDate = modDate
        } else {
            startDate = Date()
        }

        // Transcribe the file as a single speaker
        let records = try await transcribeFile(
            url: url,
            sessionID: sessionID,
            speaker: .them,
            startDate: startDate,
            sampleRate: nil,
            backend: backend,
            vad: vad,
            progressBase: 0,
            progressScale: 1.0
        )

        try Task.checkCancellation()

        guard !records.isEmpty else {
            // Not a failure (#166): the pass ran to completion and the audio
            // simply holds no speech — retrying cannot change that. The
            // healer reads completed-with-no-transcript as "nothing left to
            // try" and the meeting settles into the no-transcript sentence.
            batchLog.warning("Audio import produced no records for \(sessionID)")
            status = .completed(sessionID: sessionID)
            isImporting = false
            return
        }

        // Derive endedAt from last record timestamp
        let endedAt = records.last?.timestamp ?? startDate

        // Save final transcript atomically
        await sessionRepository.saveFinalTranscript(sessionID: sessionID, records: records)

        // Update session metadata with final counts
        await sessionRepository.finalizeImportedSession(
            sessionID: sessionID,
            utteranceCount: records.count,
            endedAt: endedAt
        )

        status = .completed(sessionID: sessionID)
        isImporting = false
        batchLog.info("Audio import completed for \(sessionID): \(records.count) records")
    }

    // MARK: - Private

    private func setStatus(_ newStatus: Status) {
        status = newStatus
    }

    private func setIsImporting(_ value: Bool) {
        isImporting = value
    }

    private func runTranscription(
        sessionID: String,
        sessionRepository: SessionRepository,
        notesDirectory: URL
    ) async throws {
        batchLog.info("Starting batch transcription for \(sessionID)")
        status = .loading(sessionID: sessionID)

        // Load batch metadata
        let urls = await sessionRepository.batchAudioURLs(sessionID: sessionID)
        guard urls.mic != nil || urls.sys != nil else {
            batchLog.warning("No batch audio found for \(sessionID)")
            status = .failed("No audio files found", sessionID: sessionID)
            return
        }

        // Load timing anchors
        let anchors = await loadBatchMeta(sessionID: sessionID, sessionRepository: sessionRepository)

        // Create and prepare backend
        let backend = ParakeetBackend()
        try await backend.prepare { statusMsg in
            batchLog.info("Backend: \(statusMsg)")
        }

        try Task.checkCancellation()

        // Load VAD
        let vad = try await VadManager()

        try Task.checkCancellation()

        status = .transcribing(progress: 0, sessionID: sessionID)

        // Transcribe each audio file
        var micRecords: [SessionRecord] = []
        var sysRecords: [SessionRecord] = []

        let totalFiles = (urls.mic != nil ? 1 : 0) + (urls.sys != nil ? 1 : 0)
        var filesProcessed = 0

        if let micURL = urls.mic {
            micRecords = try await transcribeFile(
                url: micURL,
                sessionID: sessionID,
                speaker: .you,
                startDate: anchors?.micStartDate,
                sampleRate: anchors?.micSampleRate,
                anchors: anchors?.micAnchors ?? [],
                backend: backend,
                vad: vad,
                progressBase: 0,
                progressScale: 1.0 / Double(totalFiles)
            )
            filesProcessed += 1
            batchLog.info("Mic transcription: \(micRecords.count) records")
        }

        try Task.checkCancellation()

        if let sysURL = urls.sys {
            sysRecords = try await transcribeFile(
                url: sysURL,
                sessionID: sessionID,
                speaker: .them,
                startDate: anchors?.sysStartDate,
                sampleRate: anchors?.sysSampleRate,
                anchors: anchors?.sysAnchors ?? [],
                backend: backend,
                vad: vad,
                progressBase: Double(filesProcessed) / Double(totalFiles),
                progressScale: 1.0 / Double(totalFiles)
            )
            batchLog.info("Sys transcription: \(sysRecords.count) records")
        }

        try Task.checkCancellation()

        // Apply echo suppression
        AcousticEchoFilter.suppress(micRecords: &micRecords, against: sysRecords)

        // Interleave by timestamp
        var allRecords = micRecords + sysRecords
        allRecords.sort { $0.timestamp < $1.timestamp }

        guard !allRecords.isEmpty else {
            batchLog.warning("Batch transcription produced no records for \(sessionID)")
            await sessionRepository.cleanupBatchAudio(sessionID: sessionID)
            status = .completed(sessionID: sessionID)
            return
        }

        // Atomic write of final transcript + full markdown regeneration via mirroring
        await sessionRepository.saveFinalTranscript(sessionID: sessionID, records: allRecords)

        // Cleanup audio files
        await sessionRepository.cleanupBatchAudio(sessionID: sessionID)

        status = .completed(sessionID: sessionID)
        batchLog.info("Batch transcription completed for \(sessionID): \(allRecords.count) records")
    }

    // MARK: - File Transcription

    private func transcribeFile(
        url: URL,
        sessionID: String,
        speaker: Speaker,
        startDate: Date?,
        sampleRate: Double?,
        anchors: [BatchMeta.TimingAnchor] = [],
        backend: any TranscriptionBackend,
        vad: VadManager,
        progressBase: Double,
        progressScale: Double
    ) async throws -> [SessionRecord] {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            batchLog.warning("Cannot open audio file: \(url.lastPathComponent)")
            return []
        }

        let fileSampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = audioFile.length
        guard totalFrames > 0 else { return [] }

        let resolvedStartDate = startDate ?? Date()
        let resolvedSampleRate = sampleRate ?? fileSampleRate
        let clock = AnchorClock(
            startDate: resolvedStartDate,
            sampleRate: resolvedSampleRate,
            anchors: anchors
        )

        // Process in 30-second chunks
        let chunkFrames = Int64(30.0 * fileSampleRate)
        var records: [SessionRecord] = []
        var frameOffset: Int64 = 0

        while frameOffset < totalFrames {
            try Task.checkCancellation()

            let framesToRead = min(chunkFrames, totalFrames - frameOffset)
            let chunk = try readChunk(
                file: audioFile,
                startFrame: frameOffset,
                frameCount: AVAudioFrameCount(framesToRead)
            )

            guard !chunk.isEmpty else {
                frameOffset += framesToRead
                continue
            }

            // Run VAD on the chunk to find speech segments
            let speechSegments = try await detectSpeech(samples: chunk, vad: vad)

            for segment in speechSegments {
                try Task.checkCancellation()

                let text = try await backend.transcribe(segment.samples, previousContext: nil)
                guard !text.isEmpty else { continue }

                // Calculate timestamp from frame position (anchor-aware, #128)
                let sampleOffsetInFile = Double(frameOffset) + Double(segment.startSample) * fileSampleRate / 16000.0
                let timestamp = clock.date(atFrame: sampleOffsetInFile)

                records.append(SessionRecord(
                    speaker: speaker,
                    text: text,
                    timestamp: timestamp
                ))
            }

            frameOffset += framesToRead

            // Update progress
            let fileProgress = Double(frameOffset) / Double(totalFrames)
            status = .transcribing(progress: progressBase + fileProgress * progressScale, sessionID: sessionID)
        }

        return records
    }

    // MARK: - Audio Reading

    /// Read a chunk from an AVAudioFile and resample to 16kHz mono Float32.
    private func readChunk(
        file: AVAudioFile,
        startFrame: Int64,
        frameCount: AVAudioFrameCount
    ) throws -> [Float] {
        let srcFormat = file.processingFormat
        file.framePosition = startFrame

        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: readBuf)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        // Fast path: already at target format
        if srcFormat.sampleRate == 16000 && srcFormat.channelCount == 1
            && srcFormat.commonFormat == .pcmFormatFloat32 {
            guard let data = readBuf.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(readBuf.frameLength)))
        }

        // Downmix to mono first if needed
        var inputBuffer = readBuf
        if srcFormat.channelCount > 1, let src = readBuf.floatChannelData {
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: srcFormat.sampleRate,
                channels: 1,
                interleaved: false
            )!
            if let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: readBuf.frameCapacity),
               let dst = monoBuf.floatChannelData?[0] {
                monoBuf.frameLength = readBuf.frameLength
                let channels = Int(srcFormat.channelCount)
                let scale = 1.0 / Float(channels)
                for i in 0..<Int(readBuf.frameLength) {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += src[ch][i] }
                    dst[i] = sum * scale
                }
                inputBuffer = monoBuf
            }
        }

        // Resample via AVAudioConverter
        guard let converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat) else {
            // If conversion not possible, try direct extraction
            guard let data = inputBuffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(inputBuffer.frameLength)))
        }

        let ratio = 16000.0 / inputBuffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
            return []
        }

        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let inputRef = inputBuffer
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return inputRef
        }

        guard let data = outBuf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(outBuf.frameLength)))
    }

    // MARK: - VAD

    private struct SpeechSegment {
        let startSample: Int
        let samples: [Float]
    }

    /// Detect speech segments in a chunk of 16kHz mono audio using Silero VAD.
    private func detectSpeech(samples: [Float], vad: VadManager) async throws -> [SpeechSegment] {
        let vadChunkSize = 4096
        let minimumSpeechSamples = 8000

        var vadState = await vad.makeStreamState()
        var segments: [SpeechSegment] = []
        var speechBuffer: [Float] = []
        var speechStart: Int?
        var offset = 0

        while offset + vadChunkSize <= samples.count {
            try Task.checkCancellation()

            let chunk = Array(samples[offset..<(offset + vadChunkSize)])

            let result = try await vad.processStreamingChunk(
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
                    if speechStart == nil {
                        speechStart = offset
                        speechBuffer = []
                    }
                case .speechEnd:
                    if speechStart != nil {
                        speechBuffer.append(contentsOf: chunk)
                        if speechBuffer.count >= minimumSpeechSamples {
                            segments.append(SpeechSegment(
                                startSample: speechStart!,
                                samples: speechBuffer
                            ))
                        }
                        speechStart = nil
                        speechBuffer = []
                    }
                }
            }

            if speechStart != nil {
                speechBuffer.append(contentsOf: chunk)
            }

            offset += vadChunkSize
        }

        // Flush remaining speech
        if let start = speechStart, speechBuffer.count >= minimumSpeechSamples {
            segments.append(SpeechSegment(startSample: start, samples: speechBuffer))
        }

        return segments
    }

    // MARK: - Batch Meta

    private struct ResolvedAnchors {
        let micStartDate: Date?
        let sysStartDate: Date?
        let micSampleRate: Double?
        let sysSampleRate: Double?
        let micAnchors: [BatchMeta.TimingAnchor]
        let sysAnchors: [BatchMeta.TimingAnchor]
    }

    private func loadBatchMeta(
        sessionID: String,
        sessionRepository: SessionRepository
    ) async -> ResolvedAnchors? {
        guard let meta = await sessionRepository.loadBatchMeta(sessionID: sessionID) else {
            return nil
        }

        return ResolvedAnchors(
            micStartDate: meta.micStartDate,
            sysStartDate: meta.sysStartDate,
            micSampleRate: nil,
            sysSampleRate: nil,
            micAnchors: meta.micAnchors,
            sysAnchors: meta.sysAnchors
        )
    }

}

// MARK: - JSONDecoder Extension

extension JSONDecoder {
    static let iso8601Decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
