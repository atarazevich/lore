@preconcurrency import AVFoundation
import FluidAudio
import os

private let speakerLog = Logger(subsystem: "com.lore.app", category: "SpeakerFinder")

/// A diarizer as the speaker pass drives it: 16 kHz samples in, speaker
/// activity out at 10 ms a frame, `slots` probabilities per frame, slots in
/// order of arrival. Streaming, so a track is never held in memory whole and
/// the pass can stop between blocks.
protocol SpeakerActivityModel: AnyObject {
    var slots: Int { get }
    /// The frames the samples so far complete.
    func append(_ samples: [Float]) throws -> [Float]
    /// The frames still held back, up to the last sample.
    func finish() throws -> [Float]
    /// Start over, for the next track.
    func reset()
}

extension Nemotron3Diarizer: SpeakerActivityModel {
    var slots: Int { config.numSpeakers }

    func append(_ samples: [Float]) throws -> [Float] {
        appendAudio(samples)
        return try processBufferedAudio().flatMap(\.probabilities)
    }

    func finish() throws -> [Float] {
        try finishStream().flatMap(\.probabilities)
    }
}

/// 16 kHz mono speech → a voiceprint: L2-normalised, compared by cosine.
protocol VoiceEmbedder: Sendable {
    func voiceprint(of samples: [Float]) async throws -> [Float]
}

extension CampPlusEmbedder: VoiceEmbedder {
    func voiceprint(of samples: [Float]) async throws -> [Float] {
        try embed(audio: samples)
    }
}

/// A duration-weighted average of voiceprints: how a voice's pieces, and the
/// owner's, become one voiceprint.
struct VoiceprintAverage {
    private var sum: [Float] = []
    private(set) var seconds = 0.0

    mutating func add(_ vector: [Float], seconds: Double) {
        if sum.isEmpty { sum = [Float](repeating: 0, count: vector.count) }
        sum = zip(sum, vector).map { $0 + $1 * Float(seconds) }
        self.seconds += seconds
    }

    /// L2-normalised; nil before anything was added.
    var vector: [Float]? {
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? sum.map { $0 / norm } : nil
    }

    /// The runs of consecutive `true` — windows of dictation speech, frames of
    /// one voice alone.
    static func runs(_ speech: [Bool]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for index in 0...speech.count {
            let speech = index < speech.count && speech[index]
            if speech, start == nil { start = index }
            if !speech, let open = start {
                runs.append(open..<index)
                start = nil
            }
        }
        return runs
    }

    /// What a voiceprint is made from: runs of one voice's speech at least
    /// `shortest` long, longest first, cut into pieces of at most `longest`,
    /// up to `budget` in all — in whatever unit the runs are counted in.
    static func pieces(of runs: [Range<Int>], shortest: Int, longest: Int, budget: Int) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var left = budget
        for run in runs.filter({ $0.count >= shortest }).sorted(by: { $0.count > $1.count }) {
            var start = run.lowerBound
            while true {
                let count = min(run.upperBound - start, longest, left)
                guard count >= shortest else { break }
                pieces.append(start..<(start + count))
                start += count
                left -= count
            }
        }
        return pieces
    }
}

/// The meeting's speaker pass (#269), its own job after the transcript's: it
/// reads the tracks the transcript job left, the saved transcript and where
/// its lines' words are, diarizes each track on its own, makes a voiceprint
/// per voice from the stretches where it speaks alone, gives each line to the
/// voice most of its words fall in, and compares every voiceprint with the
/// owner's.
///
/// Every time goes the way the transcript's own times went — 16 kHz sample →
/// the file's frame, holes included (`FileFrameMap`) → the wall clock
/// (`AnchorClock`) — so a word and a voice are compared on one clock.
///
/// Whatever stops it short of a written map leaves no `speakers.json` and one
/// `speakerMapFailed` event; the healer bounds the attempts. The owner's
/// voiceprint is not one of those stops: without it the map is written with
/// no similarities. Cancellation is checked between blocks.
struct SpeakerFinder: Sendable {
    /// Where the models come from; tests hand in their own.
    struct Models: Sendable {
        var diarizer: @Sendable () async throws -> sending any SpeakerActivityModel
        var embedder: @Sendable () async throws -> any VoiceEmbedder
        /// The voice detector the owner's dictation speech is found with.
        var detector: @Sendable () async throws -> sending any VoiceWindowDetector
        var diarizerIdentity: String
        var embedderIdentity: String

        static let pinned = Models(
            diarizer: { try await SpeakerModels.loadDiarizer() },
            embedder: { try await SpeakerModels.loadEmbedder() },
            detector: { SileroWindowDetector(vad: try await SileroVAD.load()) },
            diarizerIdentity: SpeakerModels.diarizer.identity,
            embedderIdentity: SpeakerModels.embedder.identity
        )
    }

    /// One recorded side of the meeting and the clock its frames run on.
    struct TrackAudio {
        let track: DiagEvent.RecordingTrack
        let url: URL
        let clock: AnchorClock
    }

    /// One line of the saved transcript: its track, and where it and its words
    /// are in that track's file, in frames. Kept beside the tracks by the
    /// transcript job (`speaker-lines.json`); no text.
    struct Line: Codable, Sendable, Equatable {
        let track: DiagEvent.RecordingTrack
        let span: Span
        let words: [Span]
    }

    /// How one meeting's pass ended, for the healer.
    enum Outcome: Sendable, Equatable {
        /// Nothing more to do: the map is on disk (now or already), or there
        /// are no lines to make one for (traced). The tracks can go.
        case finished
        /// Stopped short; traced. Another attempt may do better.
        case failed
        /// Not charged, tracks kept: a saved transcript that reads as empty
        /// and waits for its repair.
        case deferred
        /// A model did not download. Not charged, tracks kept, and no speaker
        /// pass tries again this launch.
        case offline
        case cancelled
    }

    /// Where the pass stopped, and whether a model did not download.
    struct Stopped: Error {
        let stage: DiagEvent.SpeakerStage
        var offline = false
    }

    /// Diarizer activity above this is speech (the model card's default).
    static let activityThreshold: Float = 0.5
    /// A word no voice overlaps goes to the nearest voice within this.
    static let nearestVoiceSlack = 1.0
    /// A voiceprint's pieces, in seconds (`VoiceprintAverage.pieces`).
    static let shortestPiece = 1.0
    static let longestPiece = 10.0
    static let voiceprintSeconds = 60.0

    let models: Models
    let owner: OwnerVoice

    // MARK: - One meeting

    /// The pass over one meeting's tracks, from what is on disk.
    func run(sessionID: String, repository: SessionRepository, now: Date = Date()) async -> Outcome {
        if await repository.hasSpeakerMap(sessionID: sessionID) { return .finished }
        let startedAt = Date()
        let records = await repository.finalTranscript(sessionID: sessionID)
        let lines = await repository.speakerLines(sessionID: sessionID)
        guard !records.isEmpty, let lines, lines.count == records.count else {
            DiagStore.record(.speakerMapFailed(stage: .transcript, ms: Int(Date().timeIntervalSince(startedAt) * 1000)))
            // A saved transcript that reads as nothing is damaged: its tracks
            // are what repairs it. Lines that are gone or do not match leave
            // nothing to join a map to.
            return records.isEmpty ? .deferred : .finished
        }
        let urls = await repository.batchAudioURLs(sessionID: sessionID)
        let meta = await repository.loadBatchMeta(sessionID: sessionID)
        let sides: [(DiagEvent.RecordingTrack, URL?, Date?, [BatchMeta.TimingAnchor]?)] = [
            (.mic, urls.mic, meta?.micStartDate, meta?.micAnchors),
            (.system, urls.sys, meta?.sysStartDate, meta?.sysAnchors),
        ]
        let tracks = sides.compactMap { track, url, start, anchors -> TrackAudio? in
            guard let url, let rate = try? AVAudioFile(forReading: url).processingFormat.sampleRate else { return nil }
            // Words and voices are both timed on this clock, so without a
            // start date any fixed one compares them the same.
            let clock = AnchorClock(
                startDate: start ?? Date(timeIntervalSinceReferenceDate: 0), sampleRate: rate, anchors: anchors ?? [])
            return TrackAudio(track: track, url: url, clock: clock)
        }
        do {
            let map = try await map(tracks: tracks, lines: lines, records: records, now: now)
            do {
                try await repository.saveSpeakerMap(map, sessionID: sessionID)
            } catch {
                throw Stopped(stage: .write)
            }
            DiagStore.record(.speakerMapSaved(
                clusters: map.tracks.reduce(0) { $0 + $1.clusters.count },
                records: map.records.count,
                ownerKnown: map.owner != nil,
                ms: Int(Date().timeIntervalSince(startedAt) * 1000)
            ))
            return .finished
        } catch let stopped as Stopped where !Task.isCancelled {
            DiagStore.record(.speakerMapFailed(stage: stopped.stage, ms: Int(Date().timeIntervalSince(startedAt) * 1000)))
            return stopped.offline ? .offline : .failed
        } catch {
            return .cancelled
        }
    }

    /// The map for `records`, whose lines are `lines`. Throws `Stopped` or
    /// `CancellationError`.
    func map(tracks: [TrackAudio], lines: [Line], records: [SessionRecord], now: Date) async throws -> SpeakerMap {
        var stage = DiagEvent.SpeakerStage.models
        do {
            let diarizer = try await models.diarizer()
            try Task.checkCancellation()
            let embedder = try await models.embedder()
            try Task.checkCancellation()
            let ownerPrint = await ownerVoiceprint(embedder: embedder, now: now)

            var voices: [DiagEvent.RecordingTrack: [Voice]] = [:]
            var clusters: [SpeakerMap.Track] = []
            for audio in tracks {
                stage = .diarization
                diarizer.reset()
                let activity = try await Self.activity(of: audio, model: diarizer)
                let found = Self.voices(in: activity, track: audio.track, clock: audio.clock)
                stage = .voiceprints
                let prints = try await Self.voiceprints(for: found, activity: activity, url: audio.url, embedder: embedder)
                voices[audio.track] = found
                clusters.append(SpeakerMap.Track(track: audio.track, clusters: found.map { voice in
                    let print = prints[voice.slot]
                    return SpeakerMap.Cluster(
                        id: voice.id,
                        speakingSeconds: voice.speakingSeconds,
                        voiceprintSeconds: print?.seconds ?? 0,
                        voiceprint: print?.vector,
                        ownerSimilarity: print.flatMap { print in
                            ownerPrint.map { Double(CampPlusEmbedder.cosine(print.vector, $0.vector)) }
                        }
                    )
                }))
            }
            try Task.checkCancellation()

            let clocks = Dictionary(tracks.map { ($0.track, $0.clock) }) { first, _ in first }
            return SpeakerMap(
                createdAt: now,
                diarizer: models.diarizerIdentity,
                embedder: models.embedderIdentity,
                owner: ownerPrint.map {
                    .init(computedAt: $0.computedAt, recordings: $0.recordings, speechSeconds: $0.speechSeconds)
                },
                transcriptRecords: records.count,
                tracks: clusters,
                records: zip(lines, records).enumerated().map { index, pair in
                    Self.assign(pair.0, record: pair.1, index: index, clock: clocks[pair.0.track], voices: voices[pair.0.track] ?? [])
                }
            )
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            speakerLog.error("speaker pass stopped at \(stage.rawValue, privacy: .public): \(error.localizedDescription, privacy: .private)")
            throw Stopped(stage: stage, offline: error is ModelBundle.DownloadFailed)
        }
    }

    /// The owner's voiceprint, or nil — never a reason to stop the map.
    private func ownerVoiceprint(embedder: any VoiceEmbedder, now: Date) async -> OwnerVoiceprint? {
        do {
            let detector = try await models.detector()
            return try await owner.resolve(
                embedder: embedder, identity: models.embedderIdentity, detector: detector, now: now)
        } catch {
            if !(error is CancellationError) {
                speakerLog.error("owner voiceprint not made: \(error.localizedDescription, privacy: .private)")
                DiagStore.record(.ownerVoiceprint(outcome: .failed, recordings: 0, speechSeconds: 0))
            }
            return nil
        }
    }

    // MARK: - Diarizing

    /// A track's diarizer output: `slots` probabilities per 10 ms frame of the
    /// samples it was fed, and where those samples sit in the file.
    struct Activity {
        let slots: Int
        let probabilities: [Float]
        let frames: FileFrameMap

        var frameCount: Int { slots == 0 ? 0 : probabilities.count / slots }
    }

    /// 10 ms frames are 160 samples.
    static let samplesPerFrame = 160

    static func activity(of audio: TrackAudio, model: any SpeakerActivityModel) async throws -> Activity {
        var probabilities: [Float] = []
        var frames = FileFrameMap()
        try await forEachBlock(of: audio.url) { chunk, sample -> Bool in
            frames.note(chunk, atSample: sample)
            probabilities += try model.append(chunk.samples)
            return true
        }
        probabilities += try model.finish()
        return Activity(slots: model.slots, probabilities: probabilities, frames: frames)
    }

    /// Every block of the file that decoded, with the 16 kHz sample its samples
    /// begin at, until `body` says it has had enough. A hole feeds nothing;
    /// the next block's frame says where it is. The order and the counting are
    /// the same every time a file is read, so a second read finds the samples
    /// a first one numbered.
    static func forEachBlock(of url: URL, _ body: (AudioChunk, Int) async throws -> Bool) async throws {
        let reader = AudioFileChunkReader(file: try AVAudioFile(forReading: url))
        var sample = 0
        while let chunk = try reader.nextChunk() {
            try Task.checkCancellation()
            guard !chunk.samples.isEmpty else { continue }
            guard try await body(chunk, sample) else { return }
            sample += chunk.samples.count
        }
    }

    /// One voice on one track: its slot, its id, and where it spoke, in the
    /// clock's seconds (since the reference date).
    struct Voice: Equatable {
        let slot: Int
        let id: String
        let spans: [Span]
        let speakingSeconds: Double
    }

    static func voices(in activity: Activity, track: DiagEvent.RecordingTrack, clock: AnchorClock) -> [Voice] {
        let segments = Nemotron3Diarizer.segments(
            probabilities: activity.probabilities, frameCount: activity.frameCount,
            numSpeakers: activity.slots, threshold: activityThreshold
        )
        func time(_ seconds: Float) -> Double {
            let frame = activity.frames.fileFrame(atSample: Int((Double(seconds) * 16000).rounded()))
            return clock.date(atFrame: frame).timeIntervalSinceReferenceDate
        }
        return Dictionary(grouping: segments, by: \.speakerIndex)
            .sorted { $0.key < $1.key }
            .map { slot, segments in
                Voice(
                    slot: slot,
                    id: "\(track.rawValue)-\(slot + 1)",
                    spans: segments.map { Span(start: time($0.startSeconds), end: time($0.endSeconds)) },
                    speakingSeconds: segments.reduce(0) { $0 + Double($1.endSeconds - $1.startSeconds) }
                )
            }
    }

    // MARK: - Voiceprints

    struct Voiceprint: Equatable {
        let vector: [Float]
        let seconds: Double
    }

    /// Frames `[start, start + count)` where `slot` is the only voice.
    struct Alone: Equatable {
        let slot: Int
        let frames: Range<Int>
    }

    /// The pieces each voice's voiceprint is made from: where it speaks alone.
    static func aloneStretches(in activity: Activity) -> [Alone] {
        // The one voice active in each frame, if only one is.
        let only: [Int?] = (0..<activity.frameCount).map { frame in
            let row = activity.probabilities[(frame * activity.slots)..<((frame + 1) * activity.slots)]
            let active = row.indices.filter { row[$0] > activityThreshold }
            return active.count == 1 ? active[0] - frame * activity.slots : nil
        }
        return Set(only.compactMap { $0 }).flatMap { slot in
            VoiceprintAverage.pieces(
                of: VoiceprintAverage.runs(only.map { $0 == slot }),
                shortest: Int(shortestPiece * 100), longest: Int(longestPiece * 100),
                budget: Int(voiceprintSeconds * 100)
            ).map { Alone(slot: slot, frames: $0) }
        }.sorted { $0.frames.lowerBound < $1.frames.lowerBound }
    }

    /// Each voice's voiceprint: the stretches it speaks alone, read again from
    /// the file (only those — the track is not held in memory), embedded one
    /// by one, averaged by length.
    static func voiceprints(
        for voices: [Voice], activity: Activity, url: URL, embedder: any VoiceEmbedder
    ) async throws -> [Int: Voiceprint] {
        let stretches = aloneStretches(in: activity).filter { stretch in voices.contains { $0.slot == stretch.slot } }
        guard let lastSample = stretches.map({ $0.frames.upperBound * samplesPerFrame }).max() else { return [:] }

        var pieces = stretches.map { _ in [Float]() }
        try await forEachBlock(of: url) { chunk, sample -> Bool in
            let blockEnd = sample + chunk.samples.count
            for (index, stretch) in stretches.enumerated() {
                let from = max(stretch.frames.lowerBound * samplesPerFrame, sample)
                let to = min(stretch.frames.upperBound * samplesPerFrame, blockEnd)
                if from < to { pieces[index] += chunk.samples[(from - sample)..<(to - sample)] }
            }
            return blockEnd < lastSample
        }

        var averages: [Int: VoiceprintAverage] = [:]
        for (stretch, samples) in zip(stretches, pieces) where !samples.isEmpty {
            try Task.checkCancellation()
            averages[stretch.slot, default: VoiceprintAverage()]
                .add(try await embedder.voiceprint(of: samples), seconds: Double(samples.count) / 16000)
        }
        return averages.compactMapValues { average in
            average.vector.map { Voiceprint(vector: $0, seconds: average.seconds) }
        }
    }

    // MARK: - Lines

    /// The voice most of the line's words fall in. Each word goes to the voice
    /// that overlaps it longest, or failing any overlap to the nearest voice
    /// within `nearestVoiceSlack`; a line with no word timings counts as one
    /// word spanning the line.
    static func assign(
        _ line: Line, record: SessionRecord, index: Int, clock: AnchorClock?, voices: [Voice]
    ) -> SpeakerMap.Record {
        let words = line.words.isEmpty ? [line.span] : line.words
        var counts: [String: Int] = [:]
        if let clock {
            for word in words {
                let span = Span(
                    start: clock.date(atFrame: word.start).timeIntervalSinceReferenceDate,
                    end: clock.date(atFrame: word.end).timeIntervalSinceReferenceDate
                )
                if let id = voice(of: span, among: voices) { counts[id, default: 0] += 1 }
            }
        }
        let ordered = counts
            .map { SpeakerMap.Share(cluster: $0.key, words: $0.value) }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.cluster < $1.cluster }
        return SpeakerMap.Record(
            index: index,
            timestamp: record.timestamp,
            speaker: record.speaker,
            textHash: SpeakerMap.textHash(record.text),
            cluster: ordered.first?.cluster,
            words: words.count,
            split: ordered.count > 1 ? ordered : nil
        )
    }

    static func voice(of word: Span, among voices: [Voice]) -> String? {
        var overlap: [String: Double] = [:]
        var nearest: (id: String, gap: Double)?
        for voice in voices {
            for span in voice.spans {
                let shared = min(word.end, span.end) - max(word.start, span.start)
                if shared > 0 {
                    overlap[voice.id, default: 0] += shared
                } else if -shared <= nearestVoiceSlack, nearest.map({ -shared < $0.gap }) ?? true {
                    nearest = (voice.id, -shared)
                }
            }
        }
        let best = overlap.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
        return best?.key ?? nearest?.id
    }
}
