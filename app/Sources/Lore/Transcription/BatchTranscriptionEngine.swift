@preconcurrency import AVFoundation
import FluidAudio
import os

private let batchLog = Logger(subsystem: "com.lore.app", category: "BatchTranscription")

/// Maps a file frame position to wall-clock time using the timing anchors
/// persisted in batch-meta.json (#128). The recording places every buffer by
/// its capture time (#268): a gap up to `MeetingRecording.longestFill` is
/// written as silence, so within a stretch `start + frame/rate` holds. A
/// longer gap is not written out; the track starts a new stretch, and the
/// anchor at its first frame carries that frame's capture date. With two or
/// more anchors the mapping is piecewise: each frame is based on the nearest
/// anchor at-or-before it. With fewer (one stretch, or legacy meta) it is the
/// start-date math.
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
    /// A meeting's tracks stay after its transcript is saved, with where each
    /// line's words are, for the speaker pass — its own job, which deletes
    /// them (#269). Otherwise they go with the transcript job, as before.
    private let keepsTracksForSpeakers: Bool

    init(keepsTracksForSpeakers: Bool = false) {
        self.keepsTracksForSpeakers = keepsTracksForSpeakers
    }

    /// One transcribed line: the record, where its speech ends, and where it
    /// and its words are in its file's frames.
    struct FileLine {
        let record: SessionRecord
        let end: Date
        let span: Span
        let words: [Span]
    }

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

        let (backend, vad) = try await loadModels()

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
            backend: backend,
            vad: vad,
            progressBase: 0,
            progressScale: 1.0
        ).map(\.record)

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

        // Save final transcript atomically. One that did not land is not "no
        // speech": the pass fails and the healer retries.
        guard await sessionRepository.saveFinalTranscript(sessionID: sessionID, records: records) else {
            DiagStore.record(.transcriptSaveFailed)
            status = .failed("The transcript could not be saved", sessionID: sessionID)
            isImporting = false
            return
        }

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

    /// The two models one batch run transcribes through, its own copies:
    /// a batch run is off the live path and outlives no session, so it does not
    /// draw from `SharedBackendCache` and records no `modelLoad` event — the
    /// cache owns that diagnostic for the loads it serves, and these are not
    /// among them. Routing batch through it is #185.
    private func loadModels() async throws -> (backend: ParakeetBackend, vad: VadManager) {
        let backend = ParakeetBackend()
        try await backend.prepare { statusMsg in
            batchLog.info("Backend: \(statusMsg)")
        }
        try Task.checkCancellation()

        let vad = try await SileroVAD.load()
        try Task.checkCancellation()

        return (backend, vad)
    }

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

        let (backend, vad) = try await loadModels()

        status = .transcribing(progress: 0, sessionID: sessionID)

        // Transcribe each audio file
        var micLines: [FileLine] = []
        var sysLines: [FileLine] = []

        let totalFiles = (urls.mic != nil ? 1 : 0) + (urls.sys != nil ? 1 : 0)
        var filesProcessed = 0

        if let micURL = urls.mic {
            micLines = try await transcribeFile(
                url: micURL,
                sessionID: sessionID,
                speaker: .you,
                startDate: anchors?.micStartDate,
                anchors: anchors?.micAnchors ?? [],
                backend: backend,
                vad: vad,
                progressBase: 0,
                progressScale: 1.0 / Double(totalFiles)
            )
            filesProcessed += 1
            batchLog.info("Mic transcription: \(micLines.count) records")
        }

        try Task.checkCancellation()

        if let sysURL = urls.sys {
            sysLines = try await transcribeFile(
                url: sysURL,
                sessionID: sessionID,
                speaker: .them,
                startDate: anchors?.sysStartDate,
                anchors: anchors?.sysAnchors ?? [],
                backend: backend,
                vad: vad,
                progressBase: Double(filesProcessed) / Double(totalFiles),
                progressScale: 1.0 / Double(totalFiles)
            )
            batchLog.info("Sys transcription: \(sysLines.count) records")
        }

        try Task.checkCancellation()

        // Apply echo suppression
        AcousticEchoFilter.suppress(&micLines, against: sysLines.map(\.record)) { ($0.record, $0.end) }

        // Interleave by timestamp
        var lines = micLines.map { (track: DiagEvent.RecordingTrack.mic, line: $0) }
            + sysLines.map { (track: DiagEvent.RecordingTrack.system, line: $0) }
        lines.sort { $0.line.record.timestamp < $1.line.record.timestamp }
        let allRecords = lines.map(\.line.record)

        guard !allRecords.isEmpty else {
            batchLog.warning("Batch transcription produced no records for \(sessionID)")
            await sessionRepository.cleanupBatchAudio(sessionID: sessionID)
            status = .completed(sessionID: sessionID)
            return
        }

        // Atomic write of final transcript + full markdown regeneration via
        // mirroring. A transcript that did not land fails the pass and keeps
        // the tracks for the healer's retry.
        guard await sessionRepository.saveFinalTranscript(sessionID: sessionID, records: allRecords) else {
            DiagStore.record(.transcriptSaveFailed)
            status = .failed("The transcript could not be saved", sessionID: sessionID)
            return
        }

        // The tracks stay for the speaker pass only with the lines it joins to
        // (#269); otherwise they go now.
        var kept = false
        if keepsTracksForSpeakers {
            let speakerLines = lines.map { SpeakerFinder.Line(track: $0.track, span: $0.line.span, words: $0.line.words) }
            kept = await sessionRepository.saveSpeakerLines(speakerLines, sessionID: sessionID)
        }
        if !kept {
            await sessionRepository.cleanupBatchAudio(sessionID: sessionID)
        }

        status = .completed(sessionID: sessionID)
        batchLog.info("Batch transcription completed for \(sessionID): \(allRecords.count) records")
    }

    // MARK: - File Transcription

    private func transcribeFile(
        url: URL,
        sessionID: String,
        speaker: Speaker,
        startDate: Date?,
        anchors: [BatchMeta.TimingAnchor] = [],
        backend: any TranscriptionBackend,
        vad: VadManager,
        progressBase: Double,
        progressScale: Double
    ) async throws -> [FileLine] {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            batchLog.warning("Cannot open audio file: \(url.lastPathComponent)")
            return []
        }
        let reader = AudioFileChunkReader(file: audioFile)

        let totalFrames = audioFile.length
        guard totalFrames > 0 else { return [] }

        let resolvedStartDate = startDate ?? Date()
        let clock = AnchorClock(
            startDate: resolvedStartDate,
            sampleRate: audioFile.processingFormat.sampleRate,
            anchors: anchors
        )

        // 30-second blocks, one voice detector across them and one model call
        // per segment (`AudioFileSpeech`, shared with `lore transcribe`, #254, #273).
        let reading = try await AudioFileSpeech(backend: backend, vad: vad).read(nextChunk: reader.nextChunk) { chunk in
            let fileProgress = Double(chunk.startFrame + chunk.frameCount) / Double(totalFrames)
            status = .transcribing(progress: progressBase + fileProgress * progressScale, sessionID: sessionID)
        }
        // A track that stops decoding fails the pass, as before: a partial
        // result would replace the live transcript and delete the audio, while
        // a failed pass keeps both and the healer retries within its budget.
        if let error = reading.decodeError { throw error }

        // Timestamps from the frame position (anchor-aware, #128)
        return reading.utterances.map { utterance in
            FileLine(
                record: SessionRecord(
                    speaker: speaker,
                    text: utterance.text,
                    timestamp: clock.date(atFrame: utterance.fileFrame)
                ),
                end: clock.date(atFrame: utterance.endFileFrame),
                span: Span(start: utterance.fileFrame, end: utterance.endFileFrame),
                words: utterance.words
            )
        }
    }

    // MARK: - Batch Meta

    private struct ResolvedAnchors {
        let micStartDate: Date?
        let sysStartDate: Date?
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
            micAnchors: meta.micAnchors,
            sysAnchors: meta.sysAnchors
        )
    }

}
