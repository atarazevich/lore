import Foundation

/// Where lore keeps what it heard, under `~/Library/Application Support/Lore`.
public enum LoreFiles {
    public static var root: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lore", isDirectory: true)
    }

    /// One `<UUID>.json` per dictation (#51).
    public static func dictationHistory(in root: URL) -> URL {
        root.appendingPathComponent("DictationHistory", isDirectory: true)
    }

    /// A dictation's audio, `audioFilename` in this folder.
    public static func dictationAudio(in root: URL) -> URL {
        root.appendingPathComponent("DictationAudio", isDirectory: true)
    }

    /// One `session_yyyy-MM-dd_HH-mm-ss/` folder per meeting.
    public static func sessions(in root: URL) -> URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }
}

public enum DictationEntryStatus: String, Codable, Sendable {
    /// Still being recorded, or interrupted before its words were ready.
    case audioSaved
    case transcribed
    case cleaned
    /// No text.
    case failed
}

public enum DictationVersion: String, Codable, Sendable {
    case raw
    case cleaned

    /// The text this version shows: its own, else the other one.
    public func text(raw: String?, cleaned: String?) -> String? {
        switch self {
        case .cleaned: cleaned ?? raw
        case .raw: raw ?? cleaned
        }
    }

    /// The version of an entry written before `activeVersion` was stored.
    public static func stored(cleaned: String?) -> DictationVersion {
        cleaned != nil ? .cleaned : .raw
    }
}

/// A dictation entry's shared part (#301): the fields the app's
/// `DictationHistoryEntry` decodes through this type and the `lore` command
/// reads, by one set of names and rules.
public struct StoredDictation: Decodable, Sendable, Equatable, HistoryOrdered {
    public let id: UUID
    /// Seconds since 2001 on disk — `JSONEncoder`'s default, which the app writes.
    public let timestamp: Date
    public let status: DictationEntryStatus
    public let rawText: String?
    public let cleanedText: String?
    public let durationSeconds: Double
    /// Absent in entries written before it was stored: see `DictationVersion.stored`.
    public let activeVersion: DictationVersion
    /// The file in `DictationAudio` its recording is, while the audio is kept.
    public let audioFilename: String?
    /// When it was marked for later (#324); absent while it is not marked.
    /// Written by the app alone, and a new mark replaces it.
    public let markedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, status, rawText, cleanedText, durationSeconds, activeVersion, audioFilename, markedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        status = try c.decode(DictationEntryStatus.self, forKey: .status)
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
        cleanedText = try c.decodeIfPresent(String.self, forKey: .cleanedText)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        activeVersion = try c.decodeIfPresent(DictationVersion.self, forKey: .activeVersion)
            ?? .stored(cleaned: cleanedText)
        audioFilename = try c.decodeIfPresent(String.self, forKey: .audioFilename)
        markedAt = try c.decodeIfPresent(Date.self, forKey: .markedAt)
    }

    /// The text history shows for it.
    public var text: String? { activeVersion.text(raw: rawText, cleaned: cleanedText) }

    /// Whether its words are there to read, in the words an agent reads (#324).
    public enum Readiness: String, Codable, Sendable {
        /// Transcribed: `text` is what was said.
        case ready
        /// Still being transcribed, or waiting for lore to finish it: no words yet.
        case transcribing
        /// No words came out: the audio is what is left of it.
        case failed
    }

    public var readiness: Readiness {
        switch status {
        case .audioSaved: .transcribing
        case .failed: .failed
        case .transcribed, .cleaned:
            (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .failed : .ready
        }
    }

    /// Every finished dictation in `directory`, newest first. Left out: one
    /// still recording or never transcribed (`audioSaved`), one that failed,
    /// one with no words, and anything that does not decode.
    public static func all(in directory: URL) -> [StoredDictation] {
        everything(in: directory).filter { $0.readiness == .ready }
    }

    /// Every entry in `directory` that decodes, newest first, whatever its
    /// status: a marked dictation is listed while it is being transcribed, and
    /// after its transcription failed (#324).
    public static func everything(in directory: URL) -> [StoredDictation] {
        DictationFiles.entries(Self.self, in: directory).newestFirst()
    }
}

/// The one scan of the dictation folder, for the app's history and the command.
public enum DictationFiles {
    /// One dictation's entry file; its takes are `DictationTakes.url` beside it.
    public static func url(of id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Every `<UUID>.json` in `directory` decoded as `Entry`, in no order.
    /// `unreadable` hears of each one that does not decode.
    public static func entries<Entry: Decodable>(
        _ type: Entry.Type, in directory: URL, unreadable: (URL) -> Void = { _ in }
    ) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let entry = try? decoder.decode(type, from: data) else {
                unreadable(url)
                return nil
            }
            return entry
        }
    }
}

/// Something history lists by time.
public protocol HistoryOrdered {
    var id: UUID { get }
    var timestamp: Date { get }
}

extension Sequence where Element: HistoryOrdered {
    /// History's order: newest first, the id breaking ties, so it is the same
    /// at every launch.
    public func newestFirst() -> [Element] {
        sorted { $0.timestamp != $1.timestamp ? $0.timestamp > $1.timestamp : $0.id.uuidString < $1.id.uuidString }
    }
}
