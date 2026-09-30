import FluidAudio
import Foundation
import os

private let ownerLog = Logger(subsystem: "com.lore.app", category: "OwnerVoice")

/// Where the owner's dictation audio is read from: finished recordings,
/// newest first, 16 kHz mono Float32. Production reads `DictationHistory`;
/// tests hand in their own.
protocol DictationAudioSource: Sendable {
    /// The names of up to `limit` finished recordings, newest first.
    func recentRecordings(limit: Int) async -> [String]
    /// At most the first `count` samples of a recording.
    func samples(of recording: String, upTo count: Int) async -> [Float]?
}

struct DictationHistoryAudio: DictationAudioSource {
    let history: DictationHistory
    private let directory: URL

    @MainActor
    init(history: DictationHistory) {
        self.history = history
        directory = history.audioDirectory
    }

    /// Only the list is read on the main actor. A recording still being made
    /// has no duration yet, and is left out.
    func recentRecordings(limit: Int) async -> [String] {
        await MainActor.run {
            Array(history.entries.lazy.filter { $0.durationSeconds > 0 }.compactMap(\.audioFilename).prefix(limit))
        }
    }

    func samples(of recording: String, upTo count: Int) async -> [Float]? {
        DictationHistory.readAudio(at: directory.appendingPathComponent(recording), maxSamples: count)
    }
}

/// The owner's voiceprint (#269).
struct OwnerVoiceprint: Codable, Equatable, Sendable {
    /// The embedder it was made with (`ModelBundle.identity`); a voiceprint
    /// from another is not comparable and is made again.
    let embedder: String
    let computedAt: Date
    let recordings: Int
    let speechSeconds: Double
    let vector: [Float]
}

/// The owner's voice, recognised without setup: made from the speech in their
/// recent dictations the way a meeting voice's is made (runs of speech ≥1 s,
/// pieces ≤10 s, averaged by length), so the two are comparable. Stored once
/// it rests on enough speech — `storedSeconds` over `storedRecordings` — and
/// outside the dictation audio, so dictation retention never takes it away.
/// Below that it serves the meeting at hand and is made again next time, with
/// whatever more audio there is by then. Made again, too, when the file is
/// gone or came from another embedder.
struct OwnerVoice: Sendable {
    /// `Application Support/Lore/Voices/owner.json`, 0600.
    static var defaultURL: URL {
        KnownVoices.directory(
            in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lore", isDirectory: true)
        ).appendingPathComponent("owner.json")
    }

    /// Recordings read at most, newest first, and the speech that is enough.
    static let recordings = 40
    static let enoughSeconds = 120.0
    /// The most taken from one recording, and how much of it is read for that.
    static let perRecordingSeconds = 30.0
    static let readSeconds = 90.0
    /// What a stored voiceprint rests on.
    static let storedSeconds = 60.0
    static let storedRecordings = 5

    let url: URL
    let source: any DictationAudioSource

    init(url: URL = OwnerVoice.defaultURL, source: any DictationAudioSource) {
        self.url = url
        self.source = source
    }

    /// The stored voiceprint when `identity` made it; otherwise one made now,
    /// stored if it rests on enough speech. Nil while there is none to make it
    /// from. Traced as `ownerVoiceprint` whenever one is made.
    func resolve(
        embedder: any VoiceEmbedder, identity: String, detector: any VoiceWindowDetector, now: Date
    ) async throws -> OwnerVoiceprint? {
        if let data = try? Data(contentsOf: url),
           let stored = try? SpeakerMap.decoder.decode(OwnerVoiceprint.self, from: data),
           stored.embedder == identity {
            return stored
        }
        let made = try await compute(embedder: embedder, identity: identity, detector: detector, now: now)
        var outcome = DiagEvent.Outcome.unknown
        if let made, made.speechSeconds >= Self.storedSeconds, made.recordings >= Self.storedRecordings {
            do {
                try SessionRepository.writePrivately(SpeakerMap.encoder.encode(made), to: url)
                outcome = .ok
            } catch {
                ownerLog.error("owner voiceprint not saved: \(error.localizedDescription, privacy: .private)")
            }
        }
        DiagStore.record(.ownerVoiceprint(
            outcome: outcome, recordings: made?.recordings ?? 0, speechSeconds: Int(made?.speechSeconds ?? 0)))
        return made
    }

    /// Runs of the detector's windows at or above its threshold, per recording.
    func compute(
        embedder: any VoiceEmbedder, identity: String, detector: any VoiceWindowDetector, now: Date
    ) async throws -> OwnerVoiceprint? {
        let window = SileroVAD.windowSize
        let threshold = VadConfig.default.defaultThreshold
        let windowsPerSecond = 16000.0 / Double(window)
        var average = VoiceprintAverage()
        var used = 0
        for recording in await source.recentRecordings(limit: Self.recordings) {
            guard average.seconds < Self.enoughSeconds else { break }
            try Task.checkCancellation()
            guard let samples = await source.samples(of: recording, upTo: Int(Self.readSeconds * 16000)) else { continue }
            detector.reset()
            var speech: [Bool] = []
            for index in 0..<(samples.count / window) {
                let piece = Array(samples[(index * window)..<((index + 1) * window)])
                speech.append(try await detector.read(piece).probability >= threshold)
            }
            let runs = VoiceprintAverage.runs(speech)
            let pieces = VoiceprintAverage.pieces(
                of: runs,
                shortest: Int((SpeakerFinder.shortestPiece * windowsPerSecond).rounded(.up)),
                longest: Int(SpeakerFinder.longestPiece * windowsPerSecond),
                budget: Int(Self.perRecordingSeconds * windowsPerSecond)
            )
            for piece in pieces {
                let speech = Array(samples[(piece.lowerBound * window)..<(piece.upperBound * window)])
                average.add(try await embedder.voiceprint(of: speech), seconds: Double(speech.count) / 16000)
            }
            if !pieces.isEmpty { used += 1 }
        }
        guard let vector = average.vector else { return nil }
        return OwnerVoiceprint(
            embedder: identity, computedAt: now, recordings: used, speechSeconds: average.seconds, vector: vector)
    }
}
