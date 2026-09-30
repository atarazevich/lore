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
struct SpeakerMap: Codable, Equatable, Sendable {
    static let fileName = "speakers.json"
    static let currentVersion = 1

    var version = Self.currentVersion
    let createdAt: Date
    /// The models the voices were found with, as `<model>@<revision>`.
    /// Voiceprints from different embedder revisions are not comparable.
    let diarizer: String
    let embedder: String
    /// The owner's voiceprint the similarities were measured against; nil
    /// when there was none.
    let owner: OwnerReference?
    let transcriptRecords: Int
    let tracks: [Track]
    let records: [Record]

    struct OwnerReference: Codable, Equatable, Sendable {
        let computedAt: Date
        let recordings: Int
        let speechSeconds: Double
    }

    struct Track: Codable, Equatable, Sendable {
        let track: DiagEvent.RecordingTrack
        let clusters: [Cluster]
    }

    /// One voice on one track.
    struct Cluster: Codable, Equatable, Sendable {
        /// `<track>-<n>`, n counting the diarizer's slots in order of arrival.
        let id: String
        let speakingSeconds: Double
        /// Seconds of this voice alone that the voiceprint was made from.
        let voiceprintSeconds: Double
        /// CAM++, L2-normalised; nil when the voice was never heard alone
        /// long enough to make one.
        let voiceprint: [Float]?
        /// Cosine between `voiceprint` and the owner's; nil without either.
        let ownerSimilarity: Double?
    }

    /// One line of `transcript.final.jsonl`.
    struct Record: Codable, Equatable, Sendable {
        let index: Int
        let timestamp: Date
        let speaker: Speaker
        /// `SpeakerMap.textHash` of the line's text.
        let textHash: String
        /// The voice most of the line's words belong to; nil when none of
        /// them fell in a voice.
        let cluster: String?
        let words: Int
        /// Present only when the line's words belong to more than one voice:
        /// how many went to each.
        let split: [Share]?
    }

    struct Share: Codable, Equatable, Sendable {
        let cluster: String
        let words: Int
    }

    /// The first 8 hex digits of the text's SHA-256: enough to check a join,
    /// not enough to carry the text.
    static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this map was made for these lines: the same count, and every
    /// line, by position, with the same timestamp, speaker and text hash. A map
    /// that does not join is not read — the transcript falls back to You/Them.
    func joins(_ lines: [SessionRecord]) -> Bool {
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
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
