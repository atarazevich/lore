import Foundation
import LoreFormat

/// The command lines of `lore search` and `lore show` (#301) and `lore marks`
/// (#324), read into what `LoreArchive` takes. Nil is a usage error.
public enum ArchiveCommand {
    public struct Search: Equatable, Sendable {
        public var query: LoreArchive.Query
        public var json: Bool
    }

    public struct Show: Equatable, Sendable {
        public var id: String
        public var notes: Bool
        public var raw: Bool
    }

    /// `lore marks` lists, `lore marks take` signs for one.
    public enum Marks: Equatable, Sendable {
        case list(json: Bool)
        case take(id: String, by: String)
    }

    public static let searchUsage =
        "usage: lore search <words> [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--dictations|--meetings] [--marked] [--limit N] [--json]"
    public static let showUsage = "usage: lore show <id|latest> [--notes] [--raw]"
    public static let marksUsage = "usage: lore marks [--json]\n       lore marks take <id> --by <agent>"

    /// The longest name an agent may sign with: it is read on a history row.
    public static let agentNameLimit = 64

    public static func parseSearch(_ arguments: [String], calendar: Calendar = .current) -> Search? {
        var search = Search(query: LoreArchive.Query(), json: false)
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": search.json = true
            case "--marked":
                guard search.query.kind != .meeting else { return nil }
                search.query.marked = true
            case "--dictations", "--meetings":
                let kind: LoreArchive.Kind = argument == "--dictations" ? .dictation : .meeting
                guard search.query.kind == nil || search.query.kind == kind,
                      !(search.query.marked && kind == .meeting) else { return nil }
                search.query.kind = kind
            case "--since":
                guard let value = rest.popFirst(), let day = date(value, calendar: calendar) else { return nil }
                search.query.since = day.start
            case "--until":
                guard let value = rest.popFirst(), let day = date(value, calendar: calendar) else { return nil }
                search.query.until = day.end
            case "--limit":
                guard let value = rest.popFirst(), let limit = Int(value), limit >= 0 else { return nil }
                search.query.limit = limit
            default:
                guard !argument.hasPrefix("--") else { return nil }
                search.query.words += argument.split(whereSeparator: \.isWhitespace).map(String.init)
            }
        }
        return search
    }

    /// `--by` takes one line of at most `agentNameLimit` characters, which is
    /// what the row will show after "Taken by".
    public static func parseMarks(_ arguments: [String]) -> Marks? {
        switch arguments.first {
        case nil: return .list(json: false)
        case "--json" where arguments.count == 1: return .list(json: true)
        case "take":
            var id: String?
            var agent: String?
            var rest = arguments.dropFirst()
            while let argument = rest.popFirst() {
                if argument == "--by" {
                    guard agent == nil, let value = rest.popFirst() else { return nil }
                    agent = value.trimmingCharacters(in: .whitespaces)
                } else {
                    guard id == nil, !argument.hasPrefix("--") else { return nil }
                    id = argument
                }
            }
            guard let id, let agent, !agent.isEmpty, agent.count <= agentNameLimit,
                  !agent.contains(where: \.isNewline) else { return nil }
            return .take(id: id, by: agent)
        default: return nil
        }
    }

    public static func parseShow(_ arguments: [String]) -> Show? {
        var show = Show(id: "", notes: false, raw: false)
        for argument in arguments {
            switch argument {
            case "--notes": show.notes = true
            case "--raw": show.raw = true
            default:
                guard !argument.hasPrefix("--"), show.id.isEmpty else { return nil }
                show.id = argument
            }
        }
        return show.id.isEmpty ? nil : show
    }

    /// `YYYY-MM-DD` is that whole day on this Mac's clock. `until` takes
    /// `end`, so a day it names is in.
    static func date(_ text: String, calendar: Calendar) -> (start: Date, end: Date)? {
        let day = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()
        // The parse is lenient (02-30 reads as 03-02): a day must read back as typed.
        guard let start = try? Date(text, strategy: day), start.formatted(day) == text,
              let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return (start, end)
    }

    /// One hit a line: when, what, the id `show` takes, then where the words are.
    public static func line(_ hit: LoreArchive.Hit, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let kind = hit.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
        let about = hit.title.map { "\($0): " } ?? ""
        return "\(formatter.string(from: hit.date))  \(kind)  \(hit.id)  \(about)\(hit.snippet)"
    }

    /// Dates as ISO 8601, keys sorted: stable for a reader that parses it.
    public static func json(_ hits: [LoreArchive.Hit]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(hits)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
