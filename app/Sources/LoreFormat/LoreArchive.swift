import Foundation

/// A meeting's `session.json` as the `lore` command reads it (#301): the
/// fields of the app's `SessionMetadata` it needs.
public struct MeetingInfo: Decodable, Sendable, Equatable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date?
    public let title: String?
    public let summary: String?
    public let tags: [String]?

    /// "Thu 15:01" in the reader's locale: the name a meeting has until it is
    /// given one (#58).
    public static func defaultTitle(startedAt: Date) -> String {
        startedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    public var displayTitle: String { title ?? Self.defaultTitle(startedAt: startedAt) }
}

/// What the `lore` command finds and shows (#301): dictations and meetings,
/// read straight from lore's folder so it works with the app closed. Nothing
/// here writes, moves or deletes a file, except `take` (#324), which appends
/// one line to a marked dictation's `.takes` sidecar and touches nothing else.
public struct LoreArchive: Sendable {
    public let root: URL

    public init(root: URL = LoreFiles.root) {
        self.root = root
    }

    public enum Kind: String, Codable, Sendable {
        case dictation
        case meeting
    }

    public struct Meeting: Sendable, Equatable {
        public let info: MeetingInfo
        public let directory: URL
    }

    public var sessionsDirectory: URL { LoreFiles.sessions(in: root) }
    public var voicesDirectory: URL { KnownVoices.directory(in: root) }

    public func dictations() -> [StoredDictation] {
        StoredDictation.all(in: LoreFiles.dictationHistory(in: root))
    }

    /// Every meeting folder with a `session.json`, newest first.
    public func meetings() -> [Meeting] {
        MeetingFiles.sessionFolders(in: sessionsDirectory, as: MeetingInfo.self)
            .map { Meeting(info: $0.meta, directory: $0.directory) }
            .sorted { $0.info.startedAt > $1.info.startedAt }
    }

    public func records(of meeting: Meeting) -> [SessionRecord] {
        MeetingFiles.loadTranscript(candidates: MeetingFiles.transcriptCandidates(
            sessionDirectory: meeting.directory, sessionsDirectory: sessionsDirectory, id: meeting.info.id))
    }

    /// The transcript with speaker names, as the review shows it.
    public func transcript(of meeting: Meeting) -> MeetingTranscript {
        let records = records(of: meeting)
        let speakers = MeetingFiles.naming(
            sessionDirectory: meeting.directory, voicesDirectory: voicesDirectory, records: records)?.speakers
        return MeetingTranscript(records: records, speakers: speakers)
    }

    public func notes(of meeting: Meeting) -> String? {
        try? String(contentsOf: meeting.directory.appendingPathComponent("notes.md"), encoding: .utf8)
    }

    // MARK: - Search

    public struct Query: Sendable, Equatable {
        public var words: [String] = []
        public var since: Date?
        /// Exclusive.
        public var until: Date?
        /// Nil for both.
        public var kind: Kind?
        /// 0 for every hit.
        public var limit = 20
        /// Only dictations marked for later that no agent has taken yet
        /// (#324): the ones `marks()` lists, words or not.
        public var marked = false

        public init() {}

        func covers(_ date: Date) -> Bool {
            (since.map { date >= $0 } ?? true) && (until.map { date < $0 } ?? true)
        }

        /// Every word is somewhere in the texts.
        func matches(_ texts: [String]) -> Bool {
            words.allSatisfy { word in texts.contains { Self.contains($0, word) } }
        }

        /// The one matching rule, for hits and snippets alike: case- and
        /// diacritic-blind, so "елка" finds "ёлка" and "cafe" finds "café".
        static func contains(_ text: String, _ word: String) -> Bool {
            word.isEmpty || text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    public struct Hit: Codable, Sendable, Equatable {
        public let kind: Kind
        /// What `lore show` takes.
        public let id: String
        public let date: Date
        /// A meeting's name; nil for a dictation.
        public let title: String?
        /// Where the first word was found, on one line.
        public let snippet: String
        /// A dictation marked for later (#324), in `lore marks` and
        /// `search --marked` only: when it was marked, whether its words are
        /// in, the whole text when they are, and the recording while it is kept.
        public var markedAt: Date? = nil
        public var status: StoredDictation.Readiness? = nil
        public var text: String? = nil
        public var audio: String? = nil
    }

    /// Hits newest first, at most `query.limit` of them; marks by when they
    /// were marked.
    public func search(_ query: Query) -> [Hit] {
        var hits: [Hit] = []
        if query.kind != .meeting {
            let entries = query.marked ? marks() : dictations()
            for entry in entries where query.covers(entry.timestamp) {
                let texts = [entry.rawText, entry.cleanedText].compactMap { $0 }
                guard query.matches(texts) else { continue }
                // The shown text, unless only the other version has the words.
                let shown = entry.text ?? ""
                let source = query.matches([shown]) ? shown : texts.first { query.matches([$0]) } ?? shown
                hits.append(dictationHit(entry, snippet: Self.snippet(of: source, around: query.words.first),
                                         marked: query.marked))
            }
        }
        if query.kind != .dictation, !query.marked {
            for meeting in meetings() where query.covers(meeting.info.startedAt) {
                let records = records(of: meeting)
                let lines = records.map(\.displayText)
                let about = [meeting.info.displayTitle, meeting.info.summary].compactMap { $0 } + (meeting.info.tags ?? [])
                let texts = about + lines + records.compactMap { $0.refinedText == nil ? nil : $0.text }
                    + [notes(of: meeting)].compactMap { $0 }
                guard query.matches(texts) else { continue }
                let first = query.words.first ?? ""
                let source = lines.first { Query.contains($0, first) } ?? texts.first { Query.contains($0, first) } ?? ""
                hits.append(Hit(
                    kind: .meeting, id: meeting.info.id, date: meeting.info.startedAt,
                    title: meeting.info.displayTitle, snippet: Self.snippet(of: source, around: first)))
            }
        }
        hits.sort { ($0.markedAt ?? $0.date) > ($1.markedAt ?? $1.date) }
        return query.limit > 0 ? Array(hits.prefix(query.limit)) : hits
    }

    /// A dictation's hit; a marked one says what became of its words.
    private func dictationHit(_ entry: StoredDictation, snippet: String, marked: Bool) -> Hit {
        guard marked else {
            return Hit(kind: .dictation, id: entry.id.uuidString, date: entry.timestamp, title: nil, snippet: snippet)
        }
        let audio = audio(of: entry)
        let shown = switch entry.readiness {
        case .ready: snippet
        case .transcribing: "(still being transcribed)"
        case .failed: audio == nil ? "(no words came out)" : "(no words came out; its audio is kept)"
        }
        return Hit(
            kind: .dictation, id: entry.id.uuidString, date: entry.timestamp, title: nil, snippet: shown,
            markedAt: entry.markedAt, status: entry.readiness,
            text: entry.readiness == .ready ? entry.text : nil, audio: audio?.path)
    }

    /// About `width` characters of `text` on one line, around the first place
    /// `word` is, with "…" where it was cut.
    public static func snippet(of text: String, around word: String?, width: Int = 120) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > width else { return flat }
        var start = flat.startIndex
        if let word, let found = flat.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
            start = flat.index(found.lowerBound, offsetBy: -width / 3, limitedBy: flat.startIndex) ?? flat.startIndex
        }
        let end = flat.index(start, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end].trimmingCharacters(in: .whitespaces)
            + (end < flat.endIndex ? "…" : "")
    }

    // MARK: - Marks (#324)

    /// Every dictation marked for later that no take has signed for, the
    /// newest mark first: an old dictation marked again lists at the top. A
    /// marked dictation is listed from the write that put it in history,
    /// before its words are in and after its transcription failed: the mark is
    /// the user's, whatever became of the words.
    public func marks() -> [StoredDictation] {
        let directory = LoreFiles.dictationHistory(in: root)
        return StoredDictation.everything(in: directory)
            .filter { entry in
                guard let markedAt = entry.markedAt else { return false }
                return DictationMark(markedAt: markedAt, takes: DictationTakes.read(entry.id, in: directory))
                    == .waiting(markedAt: markedAt)
            }
            .sorted { ($0.markedAt ?? .distantPast) > ($1.markedAt ?? .distantPast) }
    }

    /// Where a dictation's recording is, when it is still on disk.
    public func audio(of entry: StoredDictation) -> URL? {
        guard let name = entry.audioFilename else { return nil }
        let url = LoreFiles.dictationAudio(in: root).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// What `take` did.
    public enum TakeResult: Equatable, Sendable {
        /// Signed for: the first take of this mark.
        case taken
        /// Signed for too, and recorded; an earlier take came first.
        case alreadyTaken(DictationTake)
        /// Refused: no dictation has this id.
        case unknown
        /// Refused: the dictation is not marked.
        case notMarked
        /// Refused for now: its words are not in yet. Nothing was written.
        case transcribing
    }

    /// Sign for a dictation's mark as `agent` (#324): one line appended to its
    /// `.takes` sidecar, the one file the command writes. The entry file is
    /// never written here. Every take is recorded, a second one too. Which
    /// take came first is read back after the append, so of two agents taking
    /// at once exactly one is told it was first.
    public func take(_ id: String, by agent: String, at now: Date = Date()) throws -> TakeResult {
        let directory = LoreFiles.dictationHistory(in: root)
        guard let uuid = UUID(uuidString: id),
              let data = try? Data(contentsOf: DictationFiles.url(of: uuid, in: directory)),
              let entry = try? JSONDecoder().decode(StoredDictation.self, from: data)
        else { return .unknown }
        guard let markedAt = entry.markedAt else { return .notMarked }
        guard entry.readiness != .transcribing else { return .transcribing }
        let mine = DictationTake(by: agent, at: now, markedAt: markedAt)
        try DictationTakes.append(mine, for: uuid, in: directory)
        guard case .taken(let first) = DictationMark(markedAt: markedAt, takes: DictationTakes.read(uuid, in: directory)),
              first.by != agent || abs(first.at.timeIntervalSince(now)) >= 0.0005
        else { return .taken }
        return .alreadyTaken(first)
    }

    // MARK: - Show

    public enum Item: Sendable, Equatable {
        case dictation(StoredDictation)
        case meeting(Meeting)

        var date: Date {
            switch self {
            case .dictation(let entry): entry.timestamp
            case .meeting(let meeting): meeting.info.startedAt
            }
        }
    }

    /// A dictation by its id (any case), a meeting by its folder name, or
    /// `latest`: the newest of either.
    public func item(_ id: String) -> Item? {
        if id == "latest" {
            return [dictations().first.map(Item.dictation), meetings().first.map(Item.meeting)]
                .compactMap { $0 }
                .max { $0.date < $1.date }
        }
        if let uuid = UUID(uuidString: id) {
            return dictations().first { $0.id == uuid }.map(Item.dictation)
        }
        return meetings().first { $0.info.id == id }.map(Item.meeting)
    }

    /// What `lore show` prints: a dictation's text (its words before cleanup
    /// under `raw`), or a meeting's name, time and transcript with speaker
    /// names, one paragraph a line, and its notes under `notes`.
    public func render(_ item: Item, notes withNotes: Bool = false, raw: Bool = false) -> String {
        switch item {
        case .dictation(let entry):
            return ((raw ? entry.rawText ?? entry.text : entry.text) ?? "") + "\n"
        case .meeting(let meeting):
            let info = meeting.info
            var out = "# \(info.displayTitle)\n"
            out += info.startedAt.formatted(date: .abbreviated, time: .shortened)
            if let end = info.endedAt { out += " – " + end.formatted(date: .omitted, time: .shortened) }
            out += "\n\n"
            let lines = transcript(of: meeting).clockLines(original: raw)
            out += lines.isEmpty ? "(no transcript)\n" : lines.joined(separator: "\n") + "\n"
            if withNotes {
                out += "\n## Notes\n\n" + (notes(of: meeting).map { $0.hasSuffix("\n") ? $0 : $0 + "\n" } ?? "(no notes)\n")
            }
            return out
        }
    }
}
