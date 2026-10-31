@preconcurrency import AVFoundation
import FluidAudio
import LoreFormat
import os

private let phoneSpeakerLog = Logger(subsystem: "com.lore.app", category: "PhoneSpeakerPass")

/// A phone note's speaker pass (#308), after its transcript: the note's one
/// recording (`SessionRepository.audioFileURL(for:)`) diarized on the Neural
/// Engine, each line given to the voice most of its words fall in, the map
/// written as `speakers.json`. The lines are the ones
/// `BatchTranscriptionEngine.transcribe(sessionID:…)` left beside the
/// recording; the clock is the session's start, as the transcript's is.
///
/// The phone knows no voice: no embedder, no voiceprints, no owner, and every
/// voice is on the system side, so no reader takes one for You. The Mac's
/// meeting pass (`SpeakerFinder`) is not involved.
///
/// The diarizer is loaded at the start of each run and held by the run alone:
/// it is released when `run` returns, so nothing of it outlives the pass.
///
/// Every run leaves one trace: `speakerMapSaved` for a map,
/// `phoneSpeakersNotFound` for no one to label, `speakerMapFailed` at the
/// stage it stopped otherwise; a model load leaves its `modelLoad(.diarizer)`.
public struct PhoneSpeakerPass: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// The note's speakers are on disk and join its transcript, now or
        /// already.
        case ok
        /// Stopped short, no map. A model or the audio that failed may do
        /// better next run; lines that are gone or do not match the
        /// transcript (`speakerMapFailed(.lines)`) do not, until the note is
        /// transcribed again — only that writes them.
        case failed
        /// No text to place, or no voice in the recording: no map, and another
        /// run over the same note finds the same.
        case nothingFound
    }

    let diarizer: @Sendable () async throws -> sending any SpeakerActivityModel
    let diarizerIdentity: String

    /// Nemotron-3 `c128-split-w8a8` on `.cpuAndNeuralEngine`, pinned
    /// (`SpeakerModels.phoneDiarizer`); downloaded on first use, about 100 MB.
    public static let pinned = PhoneSpeakerPass(
        diarizer: {
            guard let preset = Nemotron3Config.preset(named: "c128-split-w8a8") else {
                throw Nemotron3Error.modelLoadFailed("no preset c128-split-w8a8")
            }
            return try await SpeakerModels.loadDiarizer(
                SpeakerModels.phoneDiarizer, preset: preset, computeUnits: .cpuAndNeuralEngine)
        },
        diarizerIdentity: SpeakerModels.phoneDiarizer.identity
    )

    /// Runs in the caller's task and throws only `CancellationError`, checked
    /// between blocks and once more before the map is written; a cancelled
    /// run writes nothing.
    public func run(sessionID: String, repository: SessionRepository, now: Date = Date()) async throws -> Outcome {
        if await repository.hasSpeakers(sessionID: sessionID) { return .ok }
        let startedAt = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(startedAt) * 1000) }
        func stopped(at stage: DiagEvent.SpeakerStage) -> Outcome {
            DiagStore.record(.speakerMapFailed(stage: stage, ms: ms()))
            return .failed
        }
        func notFound(_ reason: DiagEvent.PhoneSpeakersAbsence) -> Outcome {
            DiagStore.record(.phoneSpeakersNotFound(reason: reason, ms: ms()))
            return .nothingFound
        }
        let records: [SessionRecord], lines: [SpeakerFinder.Line]
        switch repository.noteSpeakerMaterial(sessionID: sessionID) {
        case .noText: return notFound(.noText)
        case .noLines: return stopped(at: .lines)
        case let .ready(material, matching): (records, lines) = (material, matching)
        }
        guard let start = await repository.sessionStartDate(sessionID: sessionID),
              let url = await repository.audioFileURL(for: sessionID)
        else { return stopped(at: .diarization) } // nothing to diarize

        var stage = DiagEvent.SpeakerStage.models
        do {
            let model = try await diarizer()
            try Task.checkCancellation()
            stage = .diarization
            let clock = AnchorClock(
                startDate: start, sampleRate: try AVAudioFile(forReading: url).processingFormat.sampleRate, anchors: [])
            let audio = SpeakerFinder.TrackAudio(track: .system, url: url, clock: clock)
            let voices = SpeakerFinder.voices(
                in: try await SpeakerFinder.activity(of: audio, model: model), track: audio.track, clock: clock)
            try Task.checkCancellation()
            let placed = zip(lines, records).enumerated().map { index, pair in
                SpeakerFinder.assign(pair.0, record: pair.1, index: index, clock: clock, voices: voices)
            }
            guard placed.contains(where: { $0.cluster != nil }) else { return notFound(.noVoice) }

            stage = .write
            let map = SpeakerMap(
                createdAt: now, diarizer: diarizerIdentity, embedder: "", owner: nil,
                transcriptRecords: records.count,
                tracks: [SpeakerMap.Track(track: audio.track, clusters: voices.map {
                    SpeakerMap.Cluster(
                        id: $0.id, speakingSeconds: $0.speakingSeconds, voiceprintSeconds: 0,
                        voiceprint: nil, ownerSimilarity: nil)
                })],
                records: placed
            )
            try Task.checkCancellation()
            try await repository.saveSpeakerMap(map, sessionID: sessionID)
            DiagStore.record(.speakerMapSaved(clusters: voices.count, records: placed.count, ownerKnown: false, ms: ms()))
            return .ok
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            phoneSpeakerLog.error(
                "phone speaker pass stopped at \(stage.rawValue, privacy: .public): \(error.localizedDescription, privacy: .private)")
            return stopped(at: stage)
        }
    }
}
