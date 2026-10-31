import CryptoKit
import Foundation

/// Who spoke which line of a meeting, as the speaker pass found it (#269):
/// `sessions/<id>/speakers.json`, written after the meeting's transcript by
/// its own job, from the tracks before they are deleted.
///
/// Data only. The transcript keeps its You/Them labels; steps 3–4 of #269
/// turn this into names. So the map carries what naming will need and nothing
/// that claims a name: the voices each track holds, each line's voice, every
/// voice's voiceprint and its similarity to the owner's. No similarity is
/// read as "this is the owner" until real meetings have calibrated a
/// threshold (`no-false-positives.md`).
///
/// A map belongs to one transcript: writing a transcript removes the map.
/// `transcriptRecords` is the line count it was made for, and every line is
/// named by its position with the timestamp, speaker and a short hash of the
/// text that line carries, so a reader can check the join before trusting it.
public struct SpeakerMap: Codable, Equatable, Sendable {
    public static let fileName = "speakers.json"
    public static let currentVersion = 1

    public var version = Self.currentVersion
    public let createdAt: Date
    /// The models the voices were found with, as `<model>@<revision>`.
    /// Voiceprints from different embedder revisions are not comparable.
    public let diarizer: String
    public let embedder: String
    /// The owner's voiceprint the similarities were measured against; nil
    /// when there was none.
    public let owner: OwnerReference?
    public let transcriptRecords: Int
    public let tracks: [Track]
    public let records: [Record]

    public init(
        version: Int = Self.currentVersion, createdAt: Date, diarizer: String, embedder: String,
        owner: OwnerReference?, transcriptRecords: Int, tracks: [Track], records: [Record]
    ) {
        self.version = version
        self.createdAt = createdAt
        self.diarizer = diarizer
        self.embedder = embedder
        self.owner = owner
        self.transcriptRecords = transcriptRecords
        self.tracks = tracks
        self.records = records
    }

    public struct OwnerReference: Codable, Equatable, Sendable {
        public let computedAt: Date
        public let recordings: Int
        public let speechSeconds: Double

        public init(computedAt: Date, recordings: Int, speechSeconds: Double) {
            self.computedAt = computedAt
            self.recordings = recordings
            self.speechSeconds = speechSeconds
        }
    }

    public struct Track: Codable, Equatable, Sendable {
        public let track: RecordingTrack
        public let clusters: [Cluster]

        public init(track: RecordingTrack, clusters: [Cluster]) {
            self.track = track
            self.clusters = clusters
        }
    }

    /// One voice on one track.
    public struct Cluster: Codable, Equatable, Sendable {
        /// `<track>-<n>`, n counting the diarizer's slots in order of arrival.
        public let id: String
        public let speakingSeconds: Double
        /// Seconds of this voice alone that the voiceprint was made from.
        public let voiceprintSeconds: Double
        /// CAM++, L2-normalised; nil when the voice was never heard alone
        /// long enough to make one.
        public let voiceprint: [Float]?
        /// Cosine between `voiceprint` and the owner's; nil without either.
        public let ownerSimilarity: Double?

        public init(
            id: String, speakingSeconds: Double, voiceprintSeconds: Double, voiceprint: [Float]?, ownerSimilarity: Double?
        ) {
            self.id = id
            self.speakingSeconds = speakingSeconds
            self.voiceprintSeconds = voiceprintSeconds
            self.voiceprint = voiceprint
            self.ownerSimilarity = ownerSimilarity
        }
    }

    /// One line of `transcript.final.jsonl`.
    public struct Record: Codable, Equatable, Sendable {
        public let index: Int
        public let timestamp: Date
        public let speaker: Speaker
        /// `SpeakerMap.textHash` of the line's text.
        public let textHash: String
        /// The voice most of the line's words belong to; nil when none of
        /// them fell in a voice.
        public let cluster: String?
        public let words: Int
        /// Present only when the line's words belong to more than one voice:
        /// how many went to each.
        public let split: [Share]?

        public init(
            index: Int, timestamp: Date, speaker: Speaker, textHash: String, cluster: String?, words: Int, split: [Share]?
        ) {
            self.index = index
            self.timestamp = timestamp
            self.speaker = speaker
            self.textHash = textHash
            self.cluster = cluster
            self.words = words
            self.split = split
        }
    }

    public struct Share: Codable, Equatable, Sendable {
        public let cluster: String
        public let words: Int

        public init(cluster: String, words: Int) {
            self.cluster = cluster
            self.words = words
        }
    }

    /// The first 8 hex digits of the text's SHA-256: enough to check a join,
    /// not enough to carry the text.
    public static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this map was made for these lines: the same count, and every
    /// line, by position, with the same timestamp, speaker and text hash. A map
    /// that does not join is not read — the transcript falls back to You/Them.
    public func joins(_ lines: [SessionRecord]) -> Bool {
        guard transcriptRecords == lines.count, records.count == lines.count else { return false }
        return records.enumerated().allSatisfy { position, record in
            let line = lines[position]
            return record.index == position
                && record.timestamp == line.timestamp
                && record.speaker == line.speaker
                && record.textHash == Self.textHash(line.text)
        }
    }

    // MARK: - Files

    /// Whole seconds, like the transcript's own timestamps, so a record's
    /// timestamp here compares equal to the one in the transcript.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// One of a meeting's two recorded tracks.
public enum RecordingTrack: String, Codable, Sendable, CaseIterable {
    case mic
    case system
}
