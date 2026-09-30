import Foundation
import LoreCLIKit
import os

/// One agent's spoken reply (#256): the request the sending shell put on the
/// wire (#257), and the identity lore gives it when it arrives.
///
/// Lore never guesses where a reply came from, and it keeps no second copy of
/// what it was told: `said` is exactly the request, whose absent fields are the
/// ones that shell could not answer.
struct AgentReply: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var receivedAt = Date()
    /// What was said and where from: the text, the voice, the chat's name, the
    /// host terminal, the herdr pane, tab and workspace, the Claude Code
    /// session id and the folder.
    ///
    /// The session id is not a pid: a resumed chat keeps the id under a new
    /// process, so the pid that sent a reply says nothing about where the chat
    /// is now — `AgentChatNavigator` reads the live pid holding this id from
    /// `~/.claude/sessions` instead (#258).
    var said: CLISayRequest
}

/// Which chat a reply came from, in the two lines the player prints and the
/// words it says before reading (#267).
///
/// The owner reads three different names for one chat: the workspace and tab he
/// typed in herdr, the topic Claude Code writes into the terminal title, and the
/// folder. Only the first is what he is looking at, so it is the first line; the
/// rest is the second. Nothing here is guessed: a herdr that cannot be asked, or
/// a reply stored before this existed, falls back to the name the sending shell
/// recorded.
struct AgentChatName: Equatable, Sendable {
    /// Between the workspace and its tab, as the board prints it.
    static let inHerdr = " \u{203A} "
    /// Between the parts of the second line.
    static let between = " \u{00B7} "

    /// The labels in herdr's own bar, both or neither: a dangling `›` is not a
    /// name, and a workspace alone says less than the folder the reply carries.
    let workspace: String?
    let tab: String?
    /// The name the sending shell gave its own chat — the session's hand-given
    /// name, else its folder. What stands when herdr names no labels at all.
    let stored: String
    /// `Invoice totals are off by a cent · ledger-api · herdr`: the topic,
    /// the folder, and the app the chat runs in. Each part is left out when it
    /// says nothing, the topic goes when it is the tab's own label, and the
    /// folder goes when the first line is already the folder.
    let meta: String

    /// `ledger › invoices + api` in herdr; the chat's own stored name outside it.
    var line: String {
        guard let workspace, let tab else { return stored }
        return workspace + Self.inHerdr + tab
    }

    /// The announcement, read on its own before the reply: the same two names,
    /// with the separator spoken as a pause.
    var spoken: String {
        guard let workspace, let tab else { return stored }
        return "\(workspace), \(tab)"
    }

    /// What the row says on hover: both lines whole, because both of them cut
    /// (board §05).
    var tooltip: String {
        meta.isEmpty ? line : line + "\n" + meta
    }

    /// - Parameters:
    ///   - herdr: the last live reading, whose labels win over the ones stored
    ///     with the reply — so a tab renamed since it arrived shows its new name.
    ///   - app: the host app as this Mac names it ("Ghostty"), for a chat
    ///     outside herdr; inside herdr the app that matters is herdr itself.
    init(reply: AgentReply, herdr: HerdrReading?, app: String? = nil) {
        let live = { (id: String?, labels: [String: String]?) -> String? in
            id.flatMap { labels?[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let workspace = live(reply.said.herdrWorkspaceID, herdr?.workspaces)
            ?? reply.said.herdrWorkspaceLabel
        let tab = live(reply.said.herdrTabID, herdr?.tabs) ?? reply.said.herdrTabLabel
        if let workspace, let tab, !workspace.isEmpty, !tab.isEmpty {
            self.workspace = workspace
            self.tab = tab
        } else {
            self.workspace = nil
            self.tab = nil
        }
        stored = reply.said.name

        let topic = reply.said.topic.flatMap { written -> String? in
            guard !written.isEmpty else { return nil }
            // A topic that is the tab's own label says it twice.
            return written.caseInsensitiveCompare(tab ?? "") == .orderedSame ? nil : written
        }
        let folder = reply.said.cwd.flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent
        }
        // …and neither does the folder, when the first line is already it.
        let inHerdr = AgentChatNavigator.isInHerdr(reply)
        let first = self.workspace == nil ? stored : ""
        meta = [
            topic,
            folder.flatMap { $0.caseInsensitiveCompare(first) == .orderedSame ? nil : $0 },
            inHerdr ? "herdr" : app
        ]
            .compactMap { $0 }
            .joined(separator: Self.between)
    }
}

/// The replies in arrival order and a position that moves through them (#256).
/// There are no read/unread marks on a reply: `position` is the current reply
/// and `startedIDs` are the replies reading has begun on. Playing never removes
/// a reply; only the 51st arrival drops the oldest.
///
/// A set of the replies themselves rather than how far a watermark reached
/// (#260 review): the position jumps — a clicked row plays a reply wherever it
/// sits — and a jump forward used to mark everything it passed over as read,
/// which took those replies out of the waiting count and out of "Next up" with
/// nothing left to return them.
struct AgentReplyQueue: Codable, Sendable, Equatable {
    static let capacity = 50

    private(set) var replies: [AgentReply]
    /// Index of the current reply; `replies.count` means past the end.
    private(set) var position: Int
    /// The replies reading has begun on, or Next skipped past — the one fact
    /// the waiting count, the capsule, the faded rows and `moveToFirstWaiting`
    /// all read (#266). A reply waits until it is one of these and never after:
    /// reading only moves forward, so nothing returns to one left half-way, and
    /// a quit in the middle of a reply leaves it read rather than counted for
    /// ever as something the player will never speak.
    private(set) var startedIDs: Set<UUID>

    init(replies: [AgentReply] = [], position: Int = 0, startedIDs: Set<UUID> = []) {
        let kept = Array(replies.suffix(Self.capacity))
        let dropped = replies.count - kept.count
        let ids = Set(kept.map(\.id))
        self.replies = kept
        self.position = min(max(position - dropped, 0), kept.count)
        // A stored file cannot carry a mark for a reply that is not here.
        self.startedIDs = startedIDs.intersection(ids)
    }

    var current: AgentReply? {
        replies.indices.contains(position) ? replies[position] : nil
    }

    var currentIndex: Int? {
        current == nil ? nil : position
    }

    /// How many replies are still waiting. A mark is only ever kept for a reply
    /// the queue holds — the init intersects, `append` removes — so the two
    /// counts differ by exactly them.
    var waitingCount: Int { replies.count - startedIDs.count }

    /// The same set as rows — what the player draws faded.
    var startedIndices: Set<Int> {
        Set(replies.indices.filter { startedIDs.contains(replies[$0].id) })
    }

    /// Appends in arrival order and drops the oldest past `capacity`. Returns
    /// true when the dropped reply was the current one.
    mutating func append(_ reply: AgentReply) -> Bool {
        replies.append(reply)
        guard replies.count > Self.capacity else { return false }
        let dropped = replies.removeFirst()
        startedIDs.remove(dropped.id)
        let droppedCurrent = position == 0
        position = max(position - 1, 0)
        return droppedCurrent
    }

    /// The current reply has begun.
    mutating func markStarted() {
        guard let current else { return }
        startedIDs.insert(current.id)
    }

    /// Moves to the first reply reading has not begun on (past the end when
    /// there is none).
    mutating func moveToFirstWaiting() {
        position = replies.firstIndex { !startedIDs.contains($0.id) } ?? replies.count
    }

    /// Moves on by one; the reply moved past has been read — and only it.
    mutating func moveForward() {
        guard let current else { return }
        startedIDs.insert(current.id)
        position += 1
    }

    mutating func moveBack() {
        position = max(position - 1, 0)
    }

    /// Moves to a reply already in the queue — the row clicked in the player
    /// (#260). Moving *to* a reply hears nothing: the replies passed over keep
    /// whatever they were, exactly as going back does.
    mutating func move(to index: Int) -> Bool {
        guard replies.indices.contains(index) else { return false }
        position = index
        return true
    }
}

/// The queue on disk: one JSON file in Application Support, written atomically
/// on every change and read when the feature turns on (#256).
struct AgentReplyStore: Sendable {
    private static let log = Logger(subsystem: "com.lore.app", category: "AgentReplies")

    let fileURL: URL

    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Lore/AgentReplies.json")
    }

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// An absent or unreadable file is an empty queue: replies are a convenience
    /// copy of what agents already said in their chats, not a record to rescue.
    func load() -> AgentReplyQueue {
        guard let data = try? Data(contentsOf: fileURL) else { return AgentReplyQueue() }
        do {
            let stored = try JSONDecoder().decode(AgentReplyQueue.self, from: data)
            // Through the clamping init: a hand-edited or older file cannot put
            // the position outside the replies, or mark a reply it does not
            // hold. A file written before #266 carries a second set of marks;
            // it is a key nothing decodes now, and needs no migration.
            return AgentReplyQueue(
                replies: stored.replies, position: stored.position, startedIDs: stored.startedIDs
            )
        } catch {
            Self.log.error("agent replies unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return AgentReplyQueue()
        }
    }

    func save(_ queue: AgentReplyQueue) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(queue).write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("agent replies not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
