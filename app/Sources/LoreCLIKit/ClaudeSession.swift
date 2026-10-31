import Foundation

/// One Claude Code chat's own file, `~/.claude/sessions/<pid>.json`, as both
/// ends of the wire read it: the command names a reply's chat from it when
/// herdr does not (#257), and the app finds the process holding a session id
/// there when it goes to a chat (#258).
///
/// Every field is optional because the file is somebody else's: a version that
/// stops writing one must leave the rest readable, and a reader that wants a
/// field says so itself.
public struct ClaudeSessionFile: Decodable, Equatable, Sendable {
    /// The process that wrote the file. It can outlive that process, so
    /// liveness is asked of the system, never of the file.
    public var pid: Int32?
    public var sessionId: String?
    /// The chat's name, as the chat itself says it.
    public var name: String?
    /// Where that name came from: `user` (typed by hand), `derived` (made up
    /// from the folder), `auto` (a title Claude Code wrote). What counts: `shownName`.
    public var nameSource: String?
    public var kind: Kind?
    /// When the process wrote the file, in milliseconds since 1970: never
    /// before the process started.
    public var startedAt: Int64?
    /// A background session's own job.
    public var jobId: String?
    /// The job a chat moved to the background from its own window, which that
    /// window then shows (#288). Claude Code clears it when the window's
    /// session changes.
    public var parkedJobId: String?
    /// The folder the chat started in. What tells a background chat's agents
    /// view from another one (#293).
    public var cwd: String?

    /// What runs the chat (#288). Tolerant: a kind this version does not know
    /// still leaves the file readable.
    public enum Kind: String, Decodable, Sendable {
        /// Hosted by the Claude Code daemon, with no window of its own. Its
        /// environment is the daemon's, inherited from whichever chat started
        /// it, so its `HERDR_*` variables name that chat's pane.
        case background = "bg"
        /// A chat in a terminal, or a kind this version does not know.
        case other

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    /// The value of `nameSource` that means the owner typed it.
    public static let userNamed = "user"

    /// The name the owner sees for this chat, and nil when what he sees is its
    /// folder — lore never guesses.
    ///
    /// A chat in a terminal (#267): only a name typed by hand. A derived one is
    /// the folder with a suffix, which the folder says better, and a file that
    /// does not say where its name came from is no evidence the owner typed it.
    ///
    /// A background chat (#296) has no tab: its agents view row, which shows
    /// this `name` whether typed or made up (a fork's `name ⑂`), is its only
    /// label, and its file often says no `nameSource`. A name that is the job
    /// id, or the session id's first segment, is a placeholder, not a name.
    public var shownName: String? {
        guard kind == .background else { return nameSource == Self.userNamed ? name : nil }
        let placeholders = [jobId, sessionId?.split(separator: "-").first.map(String.init)]
        guard let name, !placeholders.contains(name) else { return nil }
        return name
    }

    public init(
        pid: Int32? = nil, sessionId: String? = nil, name: String? = nil,
        nameSource: String? = nil, kind: Kind? = nil, startedAt: Int64? = nil,
        jobId: String? = nil, parkedJobId: String? = nil, cwd: String? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.name = name
        self.nameSource = nameSource
        self.kind = kind
        self.startedAt = startedAt
        self.jobId = jobId
        self.parkedJobId = parkedJobId
        self.cwd = cwd
    }

    /// Whether the chat that wrote this file still runs: a process holds its
    /// pid, and started no later than the file was written — one that started
    /// after was given a dead chat's pid. A second of slack for the clock; a
    /// file that does not say when it was written is judged by the pid alone.
    public func isLive(started: (Int32) -> Date?) -> Bool {
        // Nothing below 1 is a process to ask about.
        guard let pid, pid > 0, let processStart = started(pid) else { return false }
        guard let startedAt else { return true }
        return processStart.timeIntervalSince1970 * 1000 <= Double(startedAt) + 1000
    }

    /// Where the files are. A `home` argument rather than `NSHomeDirectory()`,
    /// so a test names its own directory.
    public static func directory(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// Every file in `directory` that reads as one; file reads, so off the main
    /// thread. Whether its process still runs is the caller's question.
    public static func all(in directory: URL) -> [ClaudeSessionFile] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        }
    }
}
