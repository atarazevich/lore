import Foundation

/// A line's speaker as every reader shows it (#269).
public struct SpeakerLabel: Hashable, Sendable {
    public let key: SpeakerKey
    public let name: String
    /// 0 is You; n ≥ 1 is the nth speaker colour. Stable within a meeting.
    public let colour: Int
    /// The review may open the naming popover on it: a voice the map found,
    /// other than You.
    public let isNameable: Bool

    public init(key: SpeakerKey, name: String, colour: Int, isNameable: Bool) {
        self.key = key
        self.name = name
        self.colour = colour
        self.isNameable = isNameable
    }
}

/// One label lookup for a meeting's lines: the raw records read through the
/// speaker map and the names. Without a map that joins, every line keeps its
/// stored label (You/Them) and colour, as before #269.
public struct SpeakerLabels: Equatable, Sendable {
    /// Per record, by position.
    public let byRecord: [SpeakerLabel]

    public init(records: [SessionRecord], speakers: MeetingSpeakers?) {
        guard let speakers else {
            byRecord = records.map { record in
                let key = SpeakerKey(record.speaker)
                return SpeakerLabel(
                    key: key, name: record.speaker.displayLabel, colour: key.storedColour ?? 0, isNameable: false)
            }
            return
        }
        var byCluster: [String: SpeakerLabel] = [:]
        func label(_ key: SpeakerKey) -> SpeakerLabel {
            let nameable = switch key {
            case .cluster, .person: true
            case .you, .them, .remote: false
            }
            return SpeakerLabel(
                key: key, name: speakers.name(of: key), colour: speakers.colour(of: key), isNameable: nameable)
        }
        byRecord = zip(records, speakers.map.records).map { record, mapped in
            guard let cluster = mapped.cluster else { return label(record.speaker == .you ? .you : .them) }
            if let known = byCluster[cluster] { return known }
            let made = label(speakers.key(ofCluster: cluster))
            byCluster[cluster] = made
            return made
        }
    }

    /// A phone note's labels (#308, ios-notes board §05 B): each voice Speaker
    /// N, not a control. A line with no voice has no speaker of its own: it is
    /// drawn inside the turn before it, so it carries that turn's label
    /// (display only — the map records no voice for it); before the first
    /// voice, and in a note without speakers, it is `unnamed`.
    init(phoneNote records: [SessionRecord], speakers: MeetingSpeakers?) {
        var current = SpeakerLabel.unnamed
        let clusters = speakers?.map.records.map(\.cluster) ?? []
        byRecord = records.indices.map { index in
            if let speakers, index < clusters.count, let cluster = clusters[index] {
                let key = speakers.key(ofCluster: cluster)
                current = SpeakerLabel(
                    key: key, name: speakers.name(of: key), colour: speakers.colour(of: key), isNameable: false)
            }
            return current
        }
    }

    /// Each speaker once, in order of first appearance: the Markdown
    /// participants, and the popover's speakers of this meeting.
    public var speakers: [SpeakerLabel] {
        var seen: Set<SpeakerKey> = []
        // A phone note's lines with no speaker are nobody: not a participant (#308).
        return byRecord.filter { $0 != .unnamed && seen.insert($0.key).inserted }
    }
}

extension SpeakerLabel {
    /// No speaker: no name, so no name line (#308). Only phone notes have it.
    public static let unnamed = SpeakerLabel(key: .them, name: "", colour: 0, isNameable: false)
}

/// A run of one speaker's lines (#269, board §04): its paragraphs, each at the
/// time of its first line.
public struct TranscriptTurn: Equatable, Sendable {
    public let speaker: SpeakerLabel
    public var paragraphs: [Paragraph]

    public init(speaker: SpeakerLabel, paragraphs: [Paragraph]) {
        self.speaker = speaker
        self.paragraphs = paragraphs
    }

    public struct Paragraph: Equatable, Sendable {
        public let time: Date
        public var pieces: [Piece]

        public init(time: Date, pieces: [Piece]) {
            self.time = time
            self.pieces = pieces
        }
    }

    /// One line in a paragraph, by its record's position. A reply is another
    /// speaker's short line kept where it was said (§04 V2).
    public struct Piece: Equatable, Sendable {
        public let record: Int
        public let isReply: Bool

        public init(record: Int, isReply: Bool) {
            self.record = record
            self.isReply = isReply
        }
    }

    /// A paragraph's text as drawn: a line, or a reply with its speaker.
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let isReply: Bool

        public init(text: String, isReply: Bool) {
            self.text = text
            self.isReply = isReply
        }
    }
}

/// How lines become turns (#269, board §04 rules, V2). Paragraphs break only
/// between lines: each line has its own start time and runs at most ~30 s,
/// so no word times are needed.
public enum TranscriptTurns {
    /// A line of this many words or fewer by another speaker stays inside the
    /// turn when the speaker it interrupted goes on right after it.
    public static let replyWords = 3
    /// A paragraph that has run longer than this ends at the next line.
    public static let paragraphSeconds: TimeInterval = 60
    /// A paragraph that has run longer than this also ends right after a reply.
    public static let afterReplySeconds: TimeInterval = 30

    /// Turns from the lines in time order. Lines with no text are left out.
    public static func group(_ records: [SessionRecord], labels: SpeakerLabels) -> [TranscriptTurn] {
        let order = records.indices
            .filter { !records[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { (records[$0].timestamp, $0) < (records[$1].timestamp, $1) }
        var turns: [TranscriptTurn] = []
        for (position, index) in order.enumerated() {
            let record = records[index]
            let speaker = labels.byRecord[index]
            let line = TranscriptTurn.Piece(record: index, isReply: false)
            if var turn = turns.last, speaker.key == turn.speaker.key {
                var paragraph = turn.paragraphs.removeLast()
                let ran = record.timestamp.timeIntervalSince(paragraph.time)
                let afterReply = paragraph.pieces.last.map { piece in
                    piece.isReply && records[piece.record].timestamp.timeIntervalSince(paragraph.time) > afterReplySeconds
                } ?? false
                if ran > paragraphSeconds || afterReply {
                    turn.paragraphs.append(paragraph)
                    paragraph = .init(time: record.timestamp, pieces: [])
                }
                paragraph.pieces.append(line)
                turn.paragraphs.append(paragraph)
                turns[turns.count - 1] = turn
            } else if let turn = turns.last, isShort(record.text),
                      let next = order.dropFirst(position + 1).first,
                      labels.byRecord[next].key == turn.speaker.key {
                turns[turns.count - 1].paragraphs[turn.paragraphs.count - 1].pieces.append(.init(record: index, isReply: true))
            } else {
                turns.append(TranscriptTurn(speaker: speaker, paragraphs: [.init(time: record.timestamp, pieces: [line])]))
            }
        }
        return turns
    }

    /// One turn per line, in stored order: how a meeting without a speaker map
    /// reads, exactly as before #269.
    public static func lines(_ records: [SessionRecord], labels: SpeakerLabels) -> [TranscriptTurn] {
        records.indices.map { index in
            TranscriptTurn(
                speaker: labels.byRecord[index],
                paragraphs: [.init(time: records[index].timestamp, pieces: [.init(record: index, isReply: false)])]
            )
        }
    }

    /// A line joined to the one before it inside a paragraph: when that line
    /// did not end a sentence (closing quotes and brackets looked past), a
    /// first word that is a plain function word standing alone ("It was",
    /// "It's", "And", "И") is lowercased, so a sentence cut in two reads as one.
    /// Anything else — a name, "I", "A/B", "A-list", "A." — is left as it is.
    public static func continuing(_ line: String, after previous: String) -> String {
        let closers: Set<Character> = ["\"", "'", "»", "”", "’", ")", "]"]
        guard let end = previous.last(where: { !closers.contains($0) }), !".!?…".contains(end) else { return line }
        let word = line.prefix(while: \.isLetter)
        let next = line.dropFirst(word.count).first
        // Whitespace, the end, or a contraction ("It's") may follow; "A/B",
        // "A-list" and "A." may not.
        guard lowercasable.contains(String(word)),
              next.map({ $0.isWhitespace || $0 == "'" || $0 == "’" }) ?? true else { return line }
        return word.lowercased() + line.dropFirst(word.count)
    }

    /// Capitalised function words that start a line only because the line
    /// starts there. Closed, so no name is ever lowercased.
    public static let lowercasable: Set<String> = [
        "A", "An", "And", "As", "At", "But", "By", "For", "From", "He", "Her", "His", "If", "In", "Is",
        "It", "Its", "Like", "My", "Of", "On", "Or", "Our", "She", "So", "That", "The", "Their",
        "Them", "Then", "There", "They", "This", "To", "Was", "We", "Were", "What", "When", "Where",
        "Which", "Who", "With", "You", "Your",
        "А", "В", "Вот", "Да", "Если", "И", "Как", "Когда", "Мы", "На", "Не", "Но", "Ну", "Он", "Она",
        "Они", "Потому", "С", "Так", "То", "Что", "Это",
    ]

    public static func isShort(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).count <= replyWords
    }
}

// MARK: - Identity (#269)

/// A turn and a paragraph are keyed by their first line's record position,
/// which a rename or a merge regrouping the turns around them does not move.
extension TranscriptTurn: Identifiable {
    public var id: Int { paragraphs[0].id }
}

extension TranscriptTurn.Paragraph: Identifiable {
    public var id: Int { pieces[0].record }
}

extension SpeakerLabel: Identifiable {
    public var id: SpeakerKey { key }
}

/// A meeting's transcript as its readers read it (#269): the raw records, one
/// label per record, and the turns — built once per load or naming change.
/// The review, its copy, Ask Lore, the summary, the Markdown mirror and the
/// plain-text export read this; the live view, echo filter, refinement and
/// backfill keep the raw records.
public struct MeetingTranscript: Equatable, Sendable {
    public let records: [SessionRecord]
    public let speakers: MeetingSpeakers?
    public let labels: SpeakerLabels
    public let turns: [TranscriptTurn]
    /// The turns the review draws. With a map, `turns`. Without one, the
    /// stored You/Them lines grouped by the same rules (§04 V2: replies
    /// inline, paragraphs) — the view only: every other reader of a meeting
    /// without a map keeps a line each.
    public let viewTurns: [TranscriptTurn]

    public static let empty = MeetingTranscript(records: [], speakers: nil)

    /// `speakers` must already join `records` (`SpeakerMap.joins`).
    public init(records: [SessionRecord], speakers: MeetingSpeakers?) {
        self.init(records: records, speakers: speakers, labels: SpeakerLabels(records: records, speakers: speakers))
    }

    /// A phone note as the phone reads it (#308): `map`, which must already
    /// join `records`, read as Speaker 1, Speaker 2… (`SpeakerLabels(phoneNote:)`);
    /// without one, the lines with no names at all.
    public init(phoneNote records: [SessionRecord], map: SpeakerMap?) {
        let speakers = map.map(MeetingSpeakers.init(phoneMap:))
        self.init(records: records, speakers: speakers, labels: SpeakerLabels(phoneNote: records, speakers: speakers))
    }

    private init(records: [SessionRecord], speakers: MeetingSpeakers?, labels: SpeakerLabels) {
        self.records = records
        self.speakers = speakers
        self.labels = labels
        turns = speakers == nil
            ? TranscriptTurns.lines(records, labels: labels)
            : TranscriptTurns.group(records, labels: labels)
        viewTurns = speakers == nil ? TranscriptTurns.group(records, labels: labels) : turns
    }

    /// A paragraph's text: its lines joined with one space, a reply as
    /// "(Name: words)". `original` reads each line's raw text in place of its
    /// cleaned one, verbatim. A paragraph of one line is that line's text
    /// untouched.
    public func text(of paragraph: TranscriptTurn.Paragraph, original: Bool = false) -> String {
        segments(of: paragraph, original: original).map(\.text).joined(separator: " ")
    }

    /// The paragraph's text in the pieces the review draws apart: each line,
    /// and each reply as "(Name: words)" (§04 V2). Joined with one space they
    /// are `text(of:)`.
    public func segments(of paragraph: TranscriptTurn.Paragraph, original: Bool = false) -> [TranscriptTurn.Segment] {
        func line(_ index: Int) -> String {
            original ? records[index].text : records[index].displayText
        }
        if paragraph.pieces.count == 1, let only = paragraph.pieces.first, !only.isReply {
            return [.init(text: line(only.record), isReply: false)]
        }
        var previous: String?
        return paragraph.pieces.compactMap { piece in
            let text = line(piece.record).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if piece.isReply {
                return .init(text: "(\(labels.byRecord[piece.record].name): \(text))", isReply: true)
            }
            defer { previous = text }
            guard let previous, !original else { return .init(text: text, isReply: false) }
            return .init(text: TranscriptTurns.continuing(text, after: previous), isReply: false)
        }
    }

    /// Every paragraph with its speaker, in order.
    public var paragraphs: [(speaker: SpeakerLabel, paragraph: TranscriptTurn.Paragraph)] {
        turns.flatMap { turn in turn.paragraphs.map { (turn.speaker, $0) } }
    }

    // MARK: - Readers

    /// Review copy and plain-text export: "[HH:mm:ss] Name: text", one line
    /// per paragraph, at the paragraph's clock time.
    public func clockLines(original: Bool = false) -> [String] {
        paragraphs.map { speaker, paragraph in
            "[\(Self.clock.string(from: paragraph.time))] \(speaker.name): \(text(of: paragraph, original: original))"
        }
    }

    /// `HH:mm:ss`, the copy paths' clock time — the live view's copy too.
    public static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Ask Lore over a finished meeting: the copy's lines, "[HH:mm:ss] Name:
    /// text" (board §04), so an answer cites the time copy and export show.
    public var askLoreText: String {
        clockLines().joined(separator: "\n")
    }

    /// The summary's prompt: "Name: text", no times — the on-device context
    /// window is small. Paragraphs with no text are left out.
    public var enrichmentLines: [String] {
        paragraphs.compactMap { speaker, paragraph in
            let text = text(of: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : "\(speaker.name): \(text)"
        }
    }
}
