import Foundation

/// One agent's reply on its way to lore (#257): what it said, and everything
/// the sending shell knows about the chat it came from.
///
/// lore never guesses any of it. Every field is what the shell read in its own
/// environment, and a field it could not answer is absent rather than inferred
/// on the other side.
public struct CLISayRequest: Codable, Sendable, Equatable {
    /// What is read aloud.
    public var text: String
    /// The voice `lore say -v` asked for; nil leaves the choice to lore.
    public var voice: String?
    /// The name this shell can give its own chat: the name the Claude Code
    /// session was given by hand, else the folder. What the player falls back
    /// to when herdr cannot be asked for the labels the owner typed (#267).
    public var name: String
    /// What the chat is about, as Claude Code writes it into the terminal
    /// title, spinner stripped (#267). Never the chat's name: the owner does
    /// not read this anywhere, so it is the second line, not the first.
    /// Absent in a reply stored before #267, and outside a terminal that
    /// sets one.
    public var topic: String?
    /// The terminal app the chat runs in (`__CFBundleIdentifier`).
    public var hostBundleID: String?
    public var herdrPaneID: String?
    public var herdrTabID: String?
    public var herdrWorkspaceID: String?
    /// The labels on that workspace and tab, as herdr's own bar shows them at
    /// the moment the reply is sent (#267). The player reads them live by the
    /// ids above, so a tab renamed later shows its new name; these are what it
    /// falls back to — and what the very first reply of a launch is announced
    /// by, before anything has been read. Absent in a reply stored before #267,
    /// and whenever herdr did not answer the sending shell.
    public var herdrWorkspaceLabel: String?
    public var herdrTabLabel: String?
    /// Claude Code session id.
    public var sessionID: String?
    public var cwd: String?

    /// Truncating, never refusing: a reply too long to send is still worth
    /// hearing the beginning of. Every field is bounded here — the identity
    /// fields come from environment variables this process does not own, and
    /// are persisted on the other side — and bounded in bytes, which is the
    /// unit the server's line limit is in.
    public init(
        text: String,
        voice: String? = nil,
        name: String,
        topic: String? = nil,
        hostBundleID: String? = nil,
        herdrPaneID: String? = nil,
        herdrTabID: String? = nil,
        herdrWorkspaceID: String? = nil,
        herdrWorkspaceLabel: String? = nil,
        herdrTabLabel: String? = nil,
        sessionID: String? = nil,
        cwd: String? = nil
    ) {
        self.text = CLISay.capped(text, bytes: CLISay.maxTextBytes)
        self.voice = CLISay.capped(voice)
        self.name = CLISay.capped(name, bytes: CLISay.maxNameBytes)
        self.topic = topic.map { CLISay.capped($0, bytes: CLISay.maxNameBytes) }
        self.hostBundleID = CLISay.capped(hostBundleID)
        self.herdrPaneID = CLISay.capped(herdrPaneID)
        self.herdrTabID = CLISay.capped(herdrTabID)
        self.herdrWorkspaceID = CLISay.capped(herdrWorkspaceID)
        self.herdrWorkspaceLabel = herdrWorkspaceLabel.map {
            CLISay.capped($0, bytes: CLISay.maxNameBytes)
        }
        self.herdrTabLabel = herdrTabLabel.map { CLISay.capped($0, bytes: CLISay.maxNameBytes) }
        self.sessionID = CLISay.capped(sessionID)
        self.cwd = CLISay.capped(cwd)
    }
}

/// Where a chat is shown, as the environment of a process in it says (#288):
/// the herdr pane, tab and workspace, and the app. Each one read, none
/// inferred.
public struct ChatPlace: Equatable, Sendable {
    public var herdrPaneID: String?
    public var herdrTabID: String?
    public var herdrWorkspaceID: String?
    public var hostBundleID: String?

    public init(environment: [String: String]) {
        herdrPaneID = CLISay.present(environment["HERDR_PANE_ID"])
        herdrTabID = CLISay.present(environment["HERDR_TAB_ID"])
        herdrWorkspaceID = CLISay.present(environment["HERDR_WORKSPACE_ID"])
        hostBundleID = CLISay.present(environment["__CFBundleIdentifier"])
    }
}

/// Everything about `lore say` that is a decision rather than a system call
/// (#257), so both ends of the wire are tested without a terminal, a herdr or
/// a running lore: what the arguments mean, who the chat is, and when the
/// command speaks the text itself.
public enum CLISay {
    /// A spoken reply is a summary, and this is minutes of speech. Past it the
    /// text is cut, because a truncated reply read aloud beats silence.
    public static let maxTextBytes = 4_096
    /// A tab title is a few words; anything beyond this is not a name.
    public static let maxNameBytes = 200
    /// A voice, a pane id, a session id, a folder: none of them is prose, and
    /// none of them is this process's to trust unbounded.
    public static let maxFieldBytes = 512

    /// `value` cut to `limit` bytes of UTF-8, on a character boundary: a cut
    /// inside a character would not be text. Bytes and not characters because
    /// that is what the server counts (`CLIWire.maxRequestBytes`) — a Cyrillic
    /// reply is two bytes a letter, and a line over the limit is dropped
    /// unread.
    public static func capped(_ value: String, bytes limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var kept = ""
        var used = 0
        for character in value {
            let size = String(character).utf8.count
            guard used + size <= limit else { break }
            kept.append(character)
            used += size
        }
        return kept
    }

    /// One identity field, bounded; nil stays nil.
    static func capped(_ value: String?) -> String? {
        value.map { capped($0, bytes: maxFieldBytes) }
    }

    // MARK: - Arguments

    /// What one `lore say` invocation asked for.
    public enum Invocation: Equatable, Sendable {
        /// The voice when `-v` gave one, and the text as typed. A nil text
        /// means standard input, which is where `say` reads it from too.
        /// `--dry-run` prints the request instead of sending it (#288).
        case send(voice: String?, text: String?, dryRun: Bool = false)
        /// A flag this command does not know — `say` has a dozen more. The
        /// reply matters more than a usage message, so `/usr/bin/say` gets the
        /// arguments exactly as they were typed and behaves as it always did.
        case passThrough
    }

    /// `arguments` is what followed `lore say`.
    public static func parse(_ arguments: [String]) -> Invocation {
        var voice: String?
        var dryRun = false
        var words: [String] = []
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--dry-run" {
                dryRun = true
                continue
            }
            if argument == "-v" {
                guard let value = rest.popFirst() else { return .passThrough }
                // `say -v ?` lists the installed voices instead of speaking.
                guard value != "?" else { return .passThrough }
                voice = value
                continue
            }
            // Everything after `--` is the text, dashes and all, as `say`
            // itself reads it.
            if argument == "--" {
                words += rest
                break
            }
            // A word beginning with a dash is a flag, including the text of a
            // reply that happens to start with one: `say` alone knows what it
            // means.
            if argument.count > 1, argument.hasPrefix("-") { return .passThrough }
            words.append(argument)
        }
        // Several words are one sentence, as `say hello world` speaks one.
        return .send(voice: voice, text: words.isEmpty ? nil : words.joined(separator: " "), dryRun: dryRun)
    }

    // MARK: - Who is speaking

    /// The glyphs a working agent's tab title is drawn with. herdr passes the
    /// title through as the terminal set it, so they arrive with it and would
    /// otherwise be read aloud.
    private static let spinnerGlyphs = Set("◐◑◒◓●○◍◌✳✴✶✷✸✹✺✻✽∗*⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".unicodeScalars)

    /// The tab title as the user reads it, without the spinner in front.
    public static func stripSpinner(_ title: String) -> String {
        let named = title.drop { character in
            character.isWhitespace || character.unicodeScalars.allSatisfy(spinnerGlyphs.contains)
        }
        return String(named).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name this shell can give its own chat: the name the Claude Code
    /// session carries, else the folder the agent works in. Empty only for a
    /// shell with no folder to name, and then the reply is read without one.
    ///
    /// The terminal title is deliberately not here (#267). It is the topic
    /// Claude Code writes by itself, which herdr does not show in its tab bar
    /// — a reply was read out under a title nobody had ever seen, for a chat
    /// whose tab says something else. It rides along as `topic` instead, and
    /// the labels the owner typed are read from herdr on the other side.
    public static func chatName(sessionName: String?, cwd: String) -> String {
        let named = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !named.isEmpty { return named }
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        return folder == "/" ? "" : folder
    }

    /// Where the chat a reply comes from is shown (#288).
    ///
    /// A chat's own environment says it, as it always has — unless the chat is
    /// a background session. The Claude Code daemon hosts those, and its
    /// environment is inherited from whichever chat started it, so their
    /// `HERDR_*` variables name that chat's pane. A background session is shown
    /// by the window it was moved to the background from: the live chat whose
    /// `parkedJobId` is its own job, whose environment says where. Without one
    /// there is no place at all — no pane and no app — and the reply goes by
    /// its stored name.
    ///
    /// - Parameters:
    ///   - session: the chat's own session file, the one `CLAUDE_PID` names.
    ///   - sessions: every session file; read only for a background session.
    public static func place(
        environment: [String: String],
        session: ClaudeSessionFile?,
        sessions: () -> [ClaudeSessionFile],
        processes: some ProcessTable
    ) -> ChatPlace {
        guard session?.kind == .background else { return ChatPlace(environment: environment) }
        let window = session?.jobId.flatMap { job in
            sessions().first { $0.parkedJobId == job && $0.isLive(started: processes.started) }
        }
        return ChatPlace(environment: window?.pid.flatMap(processes.environment(of:)) ?? [:])
    }

    /// What `herdr api snapshot`'s answer says about this shell's own pane: the
    /// topic without its spinner, and the two labels. Every field that herdr
    /// left blank comes back nil rather than as an empty string, so nothing
    /// empty is ever sent or spoken.
    public static func herdrFacts(
        from data: Data, pane: String, tab: String?, workspace: String?
    ) -> HerdrPaneFacts? {
        guard let read = Herdr.paneFacts(from: data, pane: pane, tab: tab, workspace: workspace)
        else { return nil }
        return HerdrPaneFacts(
            title: read.title.map(stripSpinner).flatMap(present),
            workspaceLabel: present(read.workspaceLabel),
            tabLabel: present(read.tabLabel)
        )
    }

    /// Where this shell's session file is, from `CLAUDE_PID`; nil outside
    /// Claude Code. The pid has to read as a number — a path is built from it.
    public static func sessionPath(environment: [String: String], home: String) -> String? {
        guard let pid = present(environment["CLAUDE_PID"]), Int(pid) != nil else { return nil }
        return ClaudeSessionFile.directory(home: home).appendingPathComponent("\(pid).json").path
    }

    /// One reply as its own shell describes it: the host terminal, the herdr
    /// pane and its labels, the Claude Code session, the folder — each one read,
    /// none inferred. `place` is `place(environment:…)`'s answer.
    public static func request(
        text: String,
        voice: String?,
        environment: [String: String],
        cwd: String,
        place: ChatPlace,
        herdr: HerdrPaneFacts?,
        session: ClaudeSessionFile?
    ) -> CLISayRequest {
        CLISayRequest(
            text: text,
            voice: voice,
            // Only a name the owner typed himself: a derived one is the folder
            // with a suffix, which the folder says better (#267).
            name: chatName(sessionName: session?.handGivenName, cwd: cwd),
            topic: present(herdr?.title),
            hostBundleID: place.hostBundleID,
            herdrPaneID: place.herdrPaneID,
            herdrTabID: place.herdrTabID,
            herdrWorkspaceID: place.herdrWorkspaceID,
            herdrWorkspaceLabel: present(herdr?.workspaceLabel),
            herdrTabLabel: present(herdr?.tabLabel),
            sessionID: present(environment["CLAUDE_CODE_SESSION_ID"]) ?? present(session?.sessionId),
            cwd: present(cwd)
        )
    }

    /// A variable set to nothing is one the shell did not set.
    static func present(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    // MARK: - Who speaks

    /// Whether the command speaks the text itself. lore takes the reply only
    /// when it says it did: no answer at all — nothing listening, a refused
    /// connection, an answer that did not arrive in time — and a lore that is
    /// not taking replies both leave the words to `say`, which is what a
    /// terminal did before this feature existed.
    public static func speaksHere(afterAnswer answer: CLIResponse?) -> Bool {
        answer != .queued
    }

    /// What `/usr/bin/say` is handed once lore has answered, and nil when lore
    /// took the reply and there is nothing left for this process to say.
    ///
    /// The words are the ones typed, never `sent.text`: that copy is capped to
    /// fit the one line the server reads, while `say` has no line to fit and
    /// the tail of a long reply is what a terminal would have spoken. They go
    /// behind `--`, so a reply beginning with a dash is spoken rather than read
    /// as a flag.
    public static func spokenHere(
        afterAnswer answer: CLIResponse?, sent: CLISayRequest, typed text: String
    ) -> [String]? {
        guard speaksHere(afterAnswer: answer) else { return nil }
        return (sent.voice.map { ["-v", $0] } ?? []) + ["--", text]
    }
}
