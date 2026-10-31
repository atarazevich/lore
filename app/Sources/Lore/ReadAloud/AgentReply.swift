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
    /// When lore took it in: what its row's time is drawn from (#264).
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

/// Which chat a reply came from: the name its row prints and the words said
/// before reading (#267, the row since #264).
///
/// The owner reads three different names for one chat: the workspace and tab he
/// typed in herdr, the topic Claude Code writes into the terminal title, and the
/// folder. Only the first is what he is looking at, so a row is named by the
/// tab, and the workspace follows only where two chats in the list share a tab's
/// name (`workspacesShown`). Nothing here is guessed: a herdr that cannot be
/// asked, or a reply stored before this existed, falls back to the name the
/// sending shell recorded.
struct AgentChatName: Equatable, Sendable {
    /// The labels in herdr's own bar, both or neither: a workspace with no tab
    /// is not a name, and a workspace alone says less than the name the reply
    /// carries.
    let workspace: String?
    let tab: String?
    /// The name the sending shell gave its own chat — the session's hand-given
    /// name, else its folder. What stands when herdr names no labels at all.
    let stored: String

    /// What the row calls the chat (board v4.0 §02): the tab as he typed it;
    /// outside a workspace, the session's own name.
    var title: String { tab ?? stored }

    /// The announcement, read on its own before the reply: the workspace and
    /// the tab, with the separator spoken as a pause.
    var spoken: String {
        guard let workspace, let tab else { return stored }
        return "\(workspace), \(tab)"
    }

    /// - Parameter herdr: the last live reading, whose labels win over the ones
    ///   stored with the reply — so a tab renamed since it arrived shows its
    ///   new name.
    init(reply: AgentReply, herdr: HerdrReading?) {
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
    }

    /// The workspace each of these rows carries after its name (board v4.0
    /// §02), in their order: a row's own workspace when another row in the list
    /// has the same title in another workspace — or in none — and nil for every
    /// other row. Computed from the list as it is drawn, never stored.
    static func workspacesShown(for names: [AgentChatName]) -> [String?] {
        let places = Dictionary(grouping: names, by: \.title).mapValues { Set($0.map(\.workspace)) }
        return names.map { (places[$0.title]?.count ?? 0) > 1 ? $0.workspace : nil }
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
    /// the waiting count, the capsule, the rows' "not heard yet" dot and
    /// `moveToFirstWaiting` all read (#266). A reply waits until it is one of these and never after:
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

    /// The reply the player has open as its card (#264): the current one, and
    /// past the last reply — reading has run out — the last one, so the chat
    /// that just spoke can still be answered. Nil only for an empty queue.
    var openIndex: Int? {
        replies.isEmpty ? nil : min(position, replies.count - 1)
    }

    /// How many replies are still waiting. A mark is only ever kept for a reply
    /// the queue holds — the init intersects, `append` removes — so the two
    /// counts differ by exactly them.
    var waitingCount: Int { replies.count - startedIDs.count }

    /// The same set as rows — the ones the player draws without the dot that
    /// marks a reply not heard yet (#264).
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
