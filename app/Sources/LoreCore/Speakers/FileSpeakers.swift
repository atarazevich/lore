import AVFoundation

/// Who spoke when in one file, for `lore transcribe --speakers` (#276): fed the
/// blocks `AssetChunkReader` gives the transcript pass as they are read, so the
/// file is read once and its samples are never held whole. The diarizer and
/// the rules are the meeting pass's (#269): `SpeakerModels.loadDiarizer`
/// (Nemotron-3 offline on the GPU), `SpeakerFinder.Listening`, the voices
/// `SpeakerFinder.voices` finds, and each word to the voice
/// `SpeakerFinder.voice(of:among:)` picks.
///
/// Loaded per request and let go after it, outside the transcript's model
/// gate, so a meeting start never waits on it.
public final class FileSpeakers {
    private var listening: SpeakerFinder.Listening

    init(model: any SpeakerActivityModel) {
        listening = SpeakerFinder.Listening(model: model)
    }

    #if os(macOS)
    /// The Mac's pinned diarizer, downloaded on first use (about 190 MB).
    public static func load() async throws -> sending FileSpeakers {
        FileSpeakers(model: try await SpeakerModels.loadMacDiarizer())
    }

    /// The request's one second try (#328), after a first that failed to load
    /// or to hear: a fresh diarizer over the file read again on its own, as
    /// the meeting pass reads a track. Throws `SpeakerFinder.Stopped`.
    public static func again(_ words: [TimedWord], url: URL) async throws -> [String?] {
        try await speakers(of: words, url: url) { try await SpeakerModels.loadMacDiarizer() }
    }
    #endif

    static func speakers(
        of words: [TimedWord], url: URL, model: () async throws -> sending any SpeakerActivityModel
    ) async throws -> [String?] {
        var stage = DiagEvent.SpeakerStage.models
        do {
            let diarizer = try await model()
            stage = .diarization
            // The file's own frames, at its own rate, counted from zero.
            let audio = SpeakerFinder.TrackAudio(track: .system, url: url, clock: AnchorClock(
                startDate: Date(timeIntervalSinceReferenceDate: 0),
                sampleRate: try AVAudioFile(forReading: url).processingFormat.sampleRate, anchors: []))
            let activity = try await SpeakerFinder.activity(of: audio, model: diarizer)
            return assign(words, SpeakerFinder.voices(in: activity, track: .system, clock: audio.clock))
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw SpeakerFinder.Stopped(stage: stage, offline: error is ModelBundle.DownloadFailed)
        }
    }

    /// The read's next block.
    public func hear(_ chunk: AudioChunk) throws {
        try listening.hear(chunk)
    }

    /// After the last block: each word's voice (an id that says nothing about
    /// order), or nil where no voice is near it. `words` are in the file's
    /// seconds.
    public func speakers(of words: [TimedWord]) throws -> [String?] {
        Self.assign(words, SpeakerFinder.voices(in: try listening.finish(), track: .system) {
            $0 / AssetChunkReader.frameRate
        })
    }

    private static func assign(_ words: [TimedWord], _ voices: [SpeakerFinder.Voice]) -> [String?] {
        words.map { SpeakerFinder.voice(of: Span(start: $0.start, end: $0.end), among: voices) }
    }
}
