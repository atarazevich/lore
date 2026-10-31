import Foundation

/// How a note recorded on the phone travels to the Mac (#309) — the names both
/// apps use.
///
/// The phone keeps its notes in its own local store, text and audio, by
/// default. The iCloud folder `Documents/Notes/` in container
/// `iCloud.com.lore.app` is only an outbox. One note is one folder in the
/// meeting format (`MeetingFiles`), named by `MeetingFiles.sessionID(startedAt:)`, with
/// `session.json` carrying `source: "phone"`, `transcript.final.jsonl`,
/// `audio/recording.m4a` and optionally `gaps.json`.
///
/// - The phone writes `.<id>.partial/` and renames it to `<id>/` last.
/// - The Mac imports a folder only when every file in it is downloaded.
/// - An audio-only note has an empty or absent `transcript.final.jsonl`; the
///   Mac transcribes it.
/// - After importing, the Mac writes `<id>/.imported`. That marker is the only
///   change the Mac ever makes to the outbox: the flow is one way.
/// - On `.imported` the phone deletes the outbox copy only. Its local note
///   stays, except that the setting "Remove audio from this phone once it's on
///   the Mac" (default off) removes the local audio. The text always stays.
public enum PhoneNotes {
    public static let containerIdentifier = "iCloud.com.lore.app"

    /// The outbox inside the container. On iOS the app resolves the container
    /// with `FileManager.url(forUbiquityContainerIdentifier:)`.
    public static let outboxRelativePath = "Documents/Notes/"

    /// `source` in a phone note's `session.json`.
    public static let source = "phone"

    /// The recording, relative to the note folder.
    public static let recordingPath = "audio/recording.m4a"

    /// Written by the Mac into the outbox note folder once it has imported it.
    public static let importedMarker = ".imported"

    /// The note's gaps, `[PhoneNoteGap]` as JSON, relative to the note folder.
    public static let gapsFileName = "gaps.json"

    #if os(macOS)
    /// `~/Library/Mobile Documents/iCloud~com~lore~app/Documents/Notes/`. The Mac
    /// reads it as a plain folder and needs no iCloud entitlement.
    public static func macOutbox(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
            .appendingPathComponent(containerIdentifier.replacingOccurrences(of: ".", with: "~"), isDirectory: true)
            .appendingPathComponent(outboxRelativePath, isDirectory: true)
    }
    #endif

    // MARK: - Folder names

    /// `.<id>.partial`, the name while the phone is still writing the note.
    public static func partialName(for id: String) -> String { ".\(id).partial" }

    /// True only for a finished note's folder name, a `MeetingFiles.sessionID`.
    public static func isFinishedNote(_ folderName: String) -> Bool {
        MeetingFiles.startDate(fromSessionID: folderName)
            .map { MeetingFiles.sessionID(startedAt: $0) == folderName } ?? false
    }

    /// The gaps of the note in `folder`, by start; none when it has no
    /// `gaps.json` or the file can't be read — a gap line explains the
    /// transcript, it never stands in the way of it.
    public static func gaps(inNote folder: URL) -> [PhoneNoteGap] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(gapsFileName)),
              let gaps = try? JSONDecoder().decode([PhoneNoteGap].self, from: data)
        else { return [] }
        return gaps.sorted { $0.start < $1.start }
    }
}

/// A stretch of the recording where audio is missing, in seconds on the
/// recording's clock.
public struct PhoneNoteGap: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable, CaseIterable {
        /// `cover`: the iPad's built-in microphone muted in hardware because
        /// the Smart Folio closed (#310).
        /// `micOff`: the built-in microphone delivered exact digital zeros
        /// for 5 s or more, which a quiet room never does (#329). It names
        /// what was measured, not the cause.
        case alarm, call, audio, cover, micOff, unknown

        /// A reason this version does not know reads as `.unknown`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Reason(rawValue: raw) ?? .unknown
        }
    }

    public let start: Double
    public let end: Double
    public let reason: Reason?

    public init(start: Double, end: Double, reason: Reason? = nil) {
        self.start = start
        self.end = end
        self.reason = reason
    }
}
