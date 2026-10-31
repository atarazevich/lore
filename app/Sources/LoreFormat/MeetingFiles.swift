import Foundation

/// How a meeting is read from its folder — `sessions/<id>/` — the one copy the
/// app's `SessionRepository` and the `lore` command both use (#301), so the
/// command reads lines and speaker names exactly as the review shows them,
/// with the app closed. Reading only: nothing here writes.
public enum MeetingFiles {
    // MARK: - Meeting id

    /// `session_yyyy-MM-dd_HH-mm-ss` in local time: the name of a meeting's
    /// folder, written by the Mac and by the phone (#309).
    public static func sessionID(startedAt: Date, timeZone: TimeZone = .current) -> String {
        "session_\(idFormatter(timeZone).string(from: startedAt))"
    }

    /// When the meeting named `id` started; nil unless `id` has the
    /// `sessionID(startedAt:)` form.
    public static func startDate(fromSessionID id: String, timeZone: TimeZone = .current) -> Date? {
        guard id.hasPrefix("session_") else { return nil }
        return idFormatter(timeZone).date(from: String(id.dropFirst("session_".count)))
    }

    /// Fixed calendar and locale so the id reads the same on every device.
    private static func idFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }

    /// Every meeting folder whose `session.json` decodes as `Meta`, with that
    /// metadata, in no order. Hidden folders — `.recently-deleted` among them —
    /// are not meetings. The app lists `SessionMetadata`, the command
    /// `MeetingInfo`, the part of it it needs.
    public static func sessionFolders<Meta: Decodable>(
        in sessionsDirectory: URL, as type: Meta.Type
    ) -> [(directory: URL, meta: Meta)] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                  let meta = try? decoder.decode(type, from: data)
            else { return nil }
            return (folder, meta)
        }
    }

    /// Transcript files in load-preference order: final, then live, then the
    /// legacy layouts (`batch.jsonl`, flat `<id>.jsonl`).
    public static func transcriptCandidates(sessionDirectory: URL, sessionsDirectory: URL, id: String) -> [URL] {
        [
            sessionDirectory.appendingPathComponent("transcript.final.jsonl"),
            sessionDirectory.appendingPathComponent("transcript.live.jsonl"),
            sessionDirectory.appendingPathComponent("batch.jsonl"),
            sessionsDirectory.appendingPathComponent("\(id).jsonl"),
        ]
    }

    /// The first candidate that holds any line.
    public static func loadTranscript(candidates: [URL]) -> [SessionRecord] {
        for url in candidates {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let records = parseJSONL(content)
            if !records.isEmpty { return records }
        }
        return []
    }

    /// One record per line. A line that does not decode is skipped: the live
    /// file of a meeting being recorded can end mid-line.
    public static func parseJSONL(_ content: String) -> [SessionRecord] {
        content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(SessionRecord.self, from: data)
            }
    }

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Speaker names (#269)

    /// The meeting's speaker map, only when it joins these lines
    /// (`SpeakerMap.joins`); otherwise nil, and the lines read You/Them.
    public static func speakerMap(sessionDirectory: URL, records: [SessionRecord]) -> SpeakerMap? {
        let url = sessionDirectory.appendingPathComponent(SpeakerMap.fileName)
        guard let data = try? Data(contentsOf: url),
              let map = try? SpeakerMap.decoder.decode(SpeakerMap.self, from: data),
              map.joins(records) else { return nil }
        return map
    }

    /// A naming file as it was found. One that is there but cannot be read —
    /// torn, or written by a later version — is kept: readers go without it
    /// and nothing writes over it.
    public enum NamingFile<Value> {
        case absent
        case read(Value)
        case unreadable(SpeakerNamesProblem)
    }

    private struct NamingVersion: Decodable { let version: Int }

    public static func readNaming<Value: Decodable>(
        _ type: Value.Type, at url: URL, currentVersion: Int
    ) -> NamingFile<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let data = try? Data(contentsOf: url)
        if let version = data.flatMap({ try? SpeakerMap.decoder.decode(NamingVersion.self, from: $0) })?.version,
           version > currentVersion {
            return .unreadable(.newerVersion)
        }
        if let data, let value = try? SpeakerMap.decoder.decode(type, from: data) {
            return .read(value)
        }
        return .unreadable(.damaged)
    }

    public static func knownVoicesURL(voicesDirectory: URL) -> URL {
        voicesDirectory.appendingPathComponent(KnownVoices.fileName)
    }

    /// The map that joins these lines, with this meeting's names and the known
    /// people, and whether a naming change may be written over them; nil
    /// without such a map. `unreadable` hears of each naming file found but
    /// not read, with where it is.
    public static func naming(
        sessionDirectory: URL,
        voicesDirectory: URL,
        records: [SessionRecord],
        unreadable: (SpeakerNamesFile, SpeakerNamesProblem, URL) -> Void = { _, _, _ in }
    ) -> (speakers: MeetingSpeakers, writable: Bool)? {
        guard let map = speakerMap(sessionDirectory: sessionDirectory, records: records) else { return nil }
        var writable = true
        func value<V: Decodable>(_ type: V.Type, _ url: URL, _ file: SpeakerNamesFile, _ version: Int) -> V? {
            switch readNaming(type, at: url, currentVersion: version) {
            case .absent: return nil
            case .read(let value): return value
            case .unreadable(let problem):
                writable = false
                unreadable(file, problem, url)
                return nil
            }
        }
        let names = value(
            SpeakerNames.self, sessionDirectory.appendingPathComponent(SpeakerNames.fileName),
            .meeting, SpeakerNames.currentVersion)
        let voices = value(
            KnownVoices.self, knownVoicesURL(voicesDirectory: voicesDirectory),
            .people, KnownVoices.currentVersion)
        return (MeetingSpeakers(map: map, names: names, voices: voices ?? KnownVoices()), writable)
    }
}

/// Which of the naming files could not be read (#269).
public enum SpeakerNamesFile: String, Codable, Sendable, CaseIterable {
    /// `Voices/names.json`, the people the owner named.
    case people
    /// `sessions/<id>/speaker-names.json`, one meeting's naming.
    case meeting
}

public enum SpeakerNamesProblem: String, Codable, Sendable, CaseIterable {
    /// It exists and does not decode (torn, or edited by hand).
    case damaged
    /// A later version of lore wrote it.
    case newerVersion
}
