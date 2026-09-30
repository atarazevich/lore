import AppKit
import Foundation
import LoreCLIKit
import Observation

/// What going to a chat comes down to (#258). One decision, read by the words
/// on the row and carried out by the click, so the two cannot disagree.
enum AgentChatMove: Equatable, Sendable {
    /// herdr still holds the chat's pane: focus it, then front the host app.
    case herdrTab
    /// The chat is gone from herdr: a new tab in its folder running the resume
    /// command, after starting the host app when it is not running.
    case newHerdrTab
    /// All lore can honestly do: bring the host app forward, starting it when
    /// it is not running. What a chat outside herdr gets — and what a herdr
    /// chat gets when herdr itself did not answer, because a chat nobody could
    /// ask about is never reopened: that would leave two of it.
    case frontApp
}

/// Where a reply's chat is right now, and what the one button on its row does
/// (#258). Read live whenever a row is shown and again on the click, never
/// stored on the reply: a chat closes while its reply sits in the list.
struct AgentChatDestination: Equatable, Sendable {
    let state: DiagEvent.ReplyChatState
    let move: AgentChatMove
    /// The host app as the user knows it ("Ghostty"); nil when the reply named
    /// an app this Mac does not have, or named none.
    let appName: String?

    /// The board's two words (`docs/design/prototypes/agent-replies-player.html`).
    var title: String {
        state == .appRunningChatOpen ? "Go to" : "Open"
    }

    /// The host app's icon is greyed while the app is not running.
    var isHostRunning: Bool {
        state != .appNotRunning
    }

    /// What the click will do, in the user's words — the board's copy table
    /// for the three herdr lines, and the move's own words when there is no
    /// herdr tab to promise. An app this Mac cannot name is "the chat's app".
    var tooltip: String {
        let app = appName ?? "the chat's app"
        switch move {
        case .herdrTab:
            return "Switches to \(app) and shows this chat's herdr tab"
        case .newHerdrTab:
            return state == .appNotRunning
                ? "Opens \(app) and resumes this chat in a new tab"
                : "Resumes this chat in a new herdr tab in \(app)"
        case .frontApp:
            return state == .appNotRunning ? "Opens \(app)" : "Switches to \(app)"
        }
    }
}

/// One live reading of everything the three states are decided from (#258):
/// what herdr holds, the chats whose process still answers, and the apps
/// running on this Mac. `herdr` is nil when herdr did not answer at all — then
/// no pane is confirmed and none is declared gone either.
struct AgentChatSnapshot: Equatable, Sendable {
    var herdr: HerdrReading?
    var liveSessions: Set<String> = []
    var runningApps: Set<String> = []
}

/// The Claude Code chats alive on this Mac: one JSON file per process in
/// `~/.claude/sessions`, carrying its `pid` and `sessionId` (#258).
///
/// A reply's own recorded pid is not what liveness is read from. It is the pid
/// that spoke, and a chat resumed since then runs under a new one while
/// keeping its session id — so the session id is what a reply is matched by,
/// and this directory is where the pid holding it now is found.
struct ClaudeSessionIndex: Sendable {

    static var defaultDirectory: URL {
        ClaudeSessionFile.directory(home: NSHomeDirectory())
    }

    let directory: URL
    /// When the process holding a pid started, nil for none. A file can
    /// outlive the process that wrote it, so the chat counts as open only
    /// while `ClaudeSessionFile.isLive` says so.
    let processStarted: @Sendable (Int32) -> Date?

    init(
        directory: URL = ClaudeSessionIndex.defaultDirectory,
        processStarted: @escaping @Sendable (Int32) -> Date? = { SystemProcessTable().started($0) }
    ) {
        self.directory = directory
        self.processStarted = processStarted
    }

    /// File reads: call this off the main thread.
    func liveSessionIDs() -> Set<String> {
        Set(ClaudeSessionFile.all(in: directory).compactMap { session in
            session.isLive(started: processStarted) ? session.sessionId : nil
        })
    }
}

/// The apps side of going to a chat (#258): which ones run, bringing one
/// forward, starting one, and how it looks. A seam, so the three states and
/// their actions are tested without launching anything.
@MainActor
protocol AgentChatHostApps: AnyObject {
    func runningBundleIDs() -> Set<String>
    func activate(bundleID: String) -> Bool
    func launch(bundleID: String) async -> Bool
    func displayName(bundleID: String) -> String?
    func icon(bundleID: String) -> NSImage?
}

@MainActor
final class SystemAgentChatHostApps: AgentChatHostApps {

    func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func activate(bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })
        else { return false }
        return app.activate()
    }

    /// Returns once the app is running: `openApplication` awaits the launch
    /// itself, so nothing here polls for it.
    func launch(bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    func displayName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    func icon(bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// From a reply to its chat (#258). lore never guesses where a reply came
/// from: the sender recorded its host app, its herdr workspace and its Claude
/// Code session (#257), and this reads, live, whether that chat is still open.
///
/// Three states, one button: the app running with the chat open is "Go to"
/// (focus the pane, bring the app forward); the app running with the chat
/// closed is "Open" (a new herdr tab in the chat's folder running the resume
/// command); the app not running is the same "Open" with a grey icon, after
/// starting the app and waiting for its herdr to answer.
///
/// Behind the switch the player owns (`AgentReplyController.isEnabled`): off,
/// there is no destination, nothing is read and no command runs.
@Observable
@MainActor
final class AgentChatNavigator {

    /// The last live reading; rows draw from it and a click takes its own.
    /// Nil until there has been one, so a row never draws a button from a
    /// state nobody read — and nil again the moment the switch goes off.
    private(set) var snapshot: AgentChatSnapshot?

    /// The feature's switch and its settings, from the one object that owns
    /// them (#256's player): the player and this can never disagree about
    /// whether the feature is on.
    @ObservationIgnored weak var replies: AgentReplyController?

    @ObservationIgnored private let herdr: HerdrClient
    @ObservationIgnored private let apps: any AgentChatHostApps
    @ObservationIgnored private let sessions: ClaudeSessionIndex
    @ObservationIgnored private let recordEvent: (DiagEvent) -> Void
    /// How long a started app's herdr is given to answer before the action is
    /// a failure, and how often it is asked.
    @ObservationIgnored private let waitCeiling: TimeInterval
    @ObservationIgnored private let pollInterval: TimeInterval

    @ObservationIgnored private var refreshTask: Task<AgentChatSnapshot, Never>?
    /// One click at a time: a second one while the first is still opening
    /// would make a second tab of the same chat.
    @ObservationIgnored private var isOpening = false

    init(
        herdr: HerdrClient = HerdrClient(),
        apps: (any AgentChatHostApps)? = nil,
        sessions: ClaudeSessionIndex = ClaudeSessionIndex(),
        recordEvent: @escaping (DiagEvent) -> Void = { DiagStore.record($0) },
        waitCeiling: TimeInterval = 10,
        pollInterval: TimeInterval = 0.25
    ) {
        self.herdr = herdr
        self.apps = apps ?? SystemAgentChatHostApps()
        self.sessions = sessions
        self.recordEvent = recordEvent
        self.waitCeiling = waitCeiling
        self.pollInterval = pollInterval
    }

    private var isEnabled: Bool {
        replies?.isEnabled == true
    }

    // MARK: - What the row shows

    /// Takes one live reading for every row at once — herdr answers in about a
    /// tenth of a second, which is not a per-row cost. Callers that arrive
    /// while a reading is in flight join it instead of starting another.
    @discardableResult
    func refresh() async -> AgentChatSnapshot? {
        guard isEnabled else {
            snapshot = nil
            return nil
        }
        if let refreshTask { return await refreshTask.value }
        let task = read()
        refreshTask = task
        let taken = await task.value
        refreshTask = nil
        snapshot = keepingLabels(taken)
        return snapshot
    }

    /// A `tab list` that alone did not answer must not rename every row twice a
    /// second: the labels last read stand until herdr names them again (#267).
    /// Nothing else is carried — a pane or workspace herdr stopped naming is a
    /// fact about where the chat is, and acting on a stale one opens a tab in
    /// the wrong place.
    private func keepingLabels(_ taken: AgentChatSnapshot) -> AgentChatSnapshot {
        guard var live = taken.herdr, live.tabs.isEmpty,
              let last = snapshot?.herdr?.tabs, !last.isEmpty
        else { return taken }
        live.tabs = last
        var kept = taken
        kept.herdr = live
        return kept
    }

    /// Reads for as long as the caller keeps this running: at once, and again
    /// every `every` while the player is up (#260 review). The player owns it,
    /// so a reading exists exactly while rows do — and the first one is taken
    /// when the player appears rather than on a poll's next tick, which left
    /// the rows with no Go to / Open at all for a moment.
    ///
    /// The interval is not a cadence for asking herdr often: #258 answers in
    /// about a tenth of a second, and two seconds is how stale a row's state
    /// may get.
    func readWhileShown(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    /// Which chat this reply came from, in the words the owner typed (#267):
    /// the workspace and tab labels of the last live reading, resolved by the
    /// ids the reply carries. Synchronous and never a call of its own — a
    /// rename shows on the next reading, and a herdr nobody could ask leaves
    /// the reply named by the labels it arrived with.
    func name(for reply: AgentReply) -> AgentChatName {
        AgentChatName(reply: reply, herdr: snapshot?.herdr, app: appName(of: reply))
    }

    /// The button for this reply, or nil when there is none: a reply that
    /// named no app and holds no pane herdr still has (a script) has no chat
    /// to be taken to.
    func destination(for reply: AgentReply) -> AgentChatDestination? {
        guard isEnabled, let snapshot, let move = Self.move(for: reply, in: snapshot) else {
            return nil
        }
        return AgentChatDestination(
            state: Self.state(for: reply, in: snapshot),
            move: move,
            appName: appName(of: reply)
        )
    }

    /// The host app's own icon, as installed on this Mac. LaunchServices —
    /// which caches both the icon and the name — is not asked while the switch
    /// is off.
    func icon(for reply: AgentReply) -> NSImage? {
        guard isEnabled, let bundleID = Self.hostApp(of: reply) else { return nil }
        return apps.icon(bundleID: bundleID)
    }

    private func appName(of reply: AgentReply) -> String? {
        guard let bundleID = Self.hostApp(of: reply) else { return nil }
        return apps.displayName(bundleID: bundleID)
    }

    // MARK: - The action

    /// Whether Fn+J has anywhere to go: a reply in the player, and no go of
    /// its own already running. The key asks before it ends the dictation
    /// gesture it arrived under (#259).
    var canOpenCurrent: Bool { isEnabled && !isOpening && replies?.currentReply != nil }

    /// Goes to the chat of the reply the player is on — its own current one, so
    /// the key that presses this holds no second reference to it (#259).
    @discardableResult
    func openCurrent() async -> DiagEvent.Outcome {
        guard let reply = replies?.currentReply else { return .failed }
        return await open(reply)
    }

    /// Goes to the reply's chat, on a reading of its own taken at the click:
    /// what the rows were drawn from may be seconds old. Never blocks the main
    /// thread — every command runs off it with a timeout, so a missing herdr
    /// or a failing call is a `failed` outcome, not a hang.
    @discardableResult
    func open(_ reply: AgentReply) async -> DiagEvent.Outcome {
        guard isEnabled, !isOpening else { return .failed }
        isOpening = true
        defer { isOpening = false }
        let live = keepingLabels(await read().value)
        snapshot = live
        guard let move = Self.move(for: reply, in: live) else { return .failed }
        let state = Self.state(for: reply, in: live)
        let outcome = await perform(move, state: state, for: reply, in: live)
        recordEvent(.agentReplyChatOpened(state: state, outcome: outcome))
        return outcome
    }

    private func perform(
        _ move: AgentChatMove, state: DiagEvent.ReplyChatState,
        for reply: AgentReply, in snapshot: AgentChatSnapshot
    ) async -> DiagEvent.Outcome {
        switch move {
        case .herdrTab:
            guard let pane = reply.said.herdrPaneID, await herdr.focus(pane: pane) else { return .failed }
            return front(reply)
        case .newHerdrTab:
            guard state == .appNotRunning else {
                return await reopen(reply, workspaces: snapshot.herdr?.workspaceIDs ?? [])
            }
            return await startThenOpen(reply)
        case .frontApp:
            guard state == .appNotRunning else { return front(reply) }
            // A launch activates the app, so there is nothing left to front.
            return await start(reply) ? .ok : .failed
        }
    }

    /// The app is not running: start it, wait for its herdr to answer — a
    /// just-started terminal needs a moment — and then go by what herdr says.
    /// The pane can still be there, since herdr's session outlives the window
    /// it was shown in; such a chat is focused, never opened a second time.
    private func startThenOpen(_ reply: AgentReply) async -> DiagEvent.Outcome {
        guard await start(reply), let live = await waitForHerdr() else { return .failed }
        if let pane = reply.said.herdrPaneID, live.panes.contains(pane) {
            guard await herdr.focus(pane: pane) else { return .failed }
            return front(reply)
        }
        return await reopen(reply, workspaces: live.workspaceIDs)
    }

    private func start(_ reply: AgentReply) async -> Bool {
        guard let bundleID = Self.hostApp(of: reply) else { return false }
        return await apps.launch(bundleID: bundleID)
    }

    /// The chat is closed: a new herdr tab in its folder, running the resume
    /// command, and the host app brought forward.
    private func reopen(_ reply: AgentReply, workspaces: Set<String>) async -> DiagEvent.Outcome {
        // The recorded workspace is used while herdr still has it; herdr picks
        // the focused one otherwise, rather than failing on a stale id.
        let workspace = reply.said.herdrWorkspaceID.flatMap { workspaces.contains($0) ? $0 : nil }
        guard let pane = await herdr.createTab(workspace: workspace, cwd: reply.said.cwd) else {
            return .failed
        }
        if let command = Self.resumeCommand(template: resumeTemplate, sessionID: reply.said.sessionID) {
            guard await herdr.run(pane: pane, command: command) else { return .failed }
        }
        return front(reply)
    }

    /// A reply that named no app has nothing to bring forward: herdr's own
    /// focus was the whole move.
    private func front(_ reply: AgentReply) -> DiagEvent.Outcome {
        guard let bundleID = Self.hostApp(of: reply) else { return .ok }
        return apps.activate(bundleID: bundleID) ? .ok : .failed
    }

    /// A reading of its own, started now. Rows share one (`refresh`); a click
    /// never joins theirs — it acts on what is true at the click.
    private func read() -> Task<AgentChatSnapshot, Never> {
        let running = apps.runningBundleIDs()
        return Task { [herdr, sessions] in
            await Self.probe(herdr: herdr, sessions: sessions, runningApps: running)
        }
    }

    private func waitForHerdr() async -> HerdrReading? {
        await poll { [herdr] in await herdr.read() }
    }

    /// Asks until it gets an answer or the ceiling passes; asks at least once,
    /// so a ceiling of zero is one attempt.
    private func poll<T>(_ attempt: () async -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(waitCeiling)
        while true {
            if let value = await attempt() { return value }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    private var resumeTemplate: String {
        replies?.settings?.activeAgentChatResumeCommand ?? AppSettings.defaultAgentChatResumeCommand
    }

    // MARK: - The decision (nonisolated for tests)

    /// The app the reply named, or nil when it named none.
    nonisolated static func hostApp(of reply: AgentReply) -> String? {
        guard let bundleID = reply.said.hostBundleID, !bundleID.isEmpty else { return nil }
        return bundleID
    }

    nonisolated static func isInHerdr(_ reply: AgentReply) -> Bool {
        !(reply.said.herdrPaneID ?? "").isEmpty
            || !(reply.said.herdrTabID ?? "").isEmpty
            || !(reply.said.herdrWorkspaceID ?? "").isEmpty
    }

    /// The chat is open while herdr still holds its pane, or a process still
    /// answers for its session. A reply that named no host app is judged by
    /// herdr instead: herdr is then the only way to its chat.
    ///
    /// A herdr chat herdr could not be asked about is never called closed —
    /// "closed" offers to resume it, and resuming a chat that is in fact
    /// running leaves two of it. Unreadable reads as open, where the only
    /// move is to bring the app forward and let the owner look.
    nonisolated static func state(
        for reply: AgentReply, in snapshot: AgentChatSnapshot
    ) -> DiagEvent.ReplyChatState {
        let hostRunning: Bool
        if let bundleID = hostApp(of: reply) {
            hostRunning = snapshot.runningApps.contains(bundleID)
        } else {
            hostRunning = snapshot.herdr != nil
        }
        guard hostRunning else { return .appNotRunning }
        if isPaneOpen(reply, in: snapshot) { return .appRunningChatOpen }
        if let sessionID = reply.said.sessionID, snapshot.liveSessions.contains(sessionID) {
            return .appRunningChatOpen
        }
        if isInHerdr(reply), snapshot.herdr == nil { return .appRunningChatOpen }
        return .appRunningChatClosed
    }

    /// What the click will do — the one decision the tooltip and the action
    /// both read. Nil when there is nothing to do at all.
    nonisolated static func move(
        for reply: AgentReply, in snapshot: AgentChatSnapshot
    ) -> AgentChatMove? {
        let hasApp = hostApp(of: reply) != nil
        switch state(for: reply, in: snapshot) {
        case .appRunningChatOpen:
            if isPaneOpen(reply, in: snapshot) { return .herdrTab }
            // Open, but not in a pane herdr has (or could be asked about):
            // the app is all there is to offer.
            return hasApp ? .frontApp : nil
        case .appRunningChatClosed:
            guard isInHerdr(reply), snapshot.herdr != nil else { return hasApp ? .frontApp : nil }
            return .newHerdrTab
        case .appNotRunning:
            // herdr is asked after the app starts, never before it.
            guard hasApp else { return nil }
            return isInHerdr(reply) ? .newHerdrTab : .frontApp
        }
    }

    private nonisolated static func isPaneOpen(
        _ reply: AgentReply, in snapshot: AgentChatSnapshot
    ) -> Bool {
        guard let pane = reply.said.herdrPaneID, let herdr = snapshot.herdr else { return false }
        return herdr.panes.contains(pane)
    }

    /// What the Settings command's own words for the chat are replaced by.
    nonisolated static let sessionPlaceholder = "<session id>"

    /// The Settings command with the chat's session filled in. Nil when the
    /// command asks for a session the reply never carried: the tab still opens
    /// in the chat's folder, and lore types nothing into it.
    nonisolated static func resumeCommand(template: String, sessionID: String?) -> String? {
        let command = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        guard command.contains(sessionPlaceholder) else { return command }
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return command.replacingOccurrences(of: sessionPlaceholder, with: sessionID)
    }

    private nonisolated static func probe(
        herdr: HerdrClient, sessions: ClaudeSessionIndex, runningApps: Set<String>
    ) async -> AgentChatSnapshot {
        async let reading = herdr.read()
        async let live = Task.detached { sessions.liveSessionIDs() }.value
        return AgentChatSnapshot(
            herdr: await reading,
            liveSessions: await live,
            runningApps: runningApps
        )
    }
}
