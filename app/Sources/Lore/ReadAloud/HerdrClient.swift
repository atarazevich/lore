import Foundation
import LoreCLIKit

/// One live reading of herdr (#258, #267): the panes it holds an agent in,
/// every workspace it has, and the labels the owner typed on its workspaces
/// and tabs.
///
/// Two calls at least, because `agent list` names only the workspaces that hold
/// an agent — measured 2026-09-14, one of nine workspaces was missing from it —
/// and a chat recorded in a workspace with no agent left in it must not be
/// judged stale and reopened somewhere else.
struct HerdrReading: Equatable, Sendable {
    var panes: Set<String> = []
    /// Workspace id → the label in herdr's own bar. Its keys are every
    /// workspace herdr has, which is what a reopened tab is placed by.
    var workspaces: [String: String] = [:]
    /// Tab id → the label in herdr's own bar (#267). Empty when `tab list`
    /// alone did not answer: a chat is then named by what the reply stored,
    /// and nothing about going to it changes.
    var tabs: [String: String] = [:]

    /// Every workspace herdr has — what a reopened tab is placed by.
    var workspaceIDs: Set<String> { Set(workspaces.keys) }
}

/// herdr as lore calls it (#258, #267): the workspace manager the owner's chats
/// run in. Six calls, each one CLI invocation over herdr's own socket — the
/// seventh, the pane's own terminal title, is made by the `lore` command in the
/// agent's own shell, so herdr's binary and that call live beside the wire, in
/// `LoreCLIKit.Herdr`.
///
/// Two measured facts shape this (2026-09-14). The CLI lives in the user's own
/// `bin`, which is not on the PATH of an app launched from Finder, so the
/// binary is resolved by path and lore is silent when it is not there. And a
/// call herdr refuses exits non-zero with its own `{"error":{…}}` on standard
/// error and nothing on standard output, so an answer is a zero status *and* a
/// decoded `result` — never a status alone, and never an empty body.
struct HerdrClient: Sendable {

    let runner: any CommandRunner
    /// Re-resolved per call: herdr may be installed while lore runs.
    let binary: @Sendable () -> URL?
    let timeout: TimeInterval

    init(
        runner: any CommandRunner = SystemCommandRunner(),
        binary: @escaping @Sendable () -> URL? = Herdr.resolveBinary,
        timeout: TimeInterval = 5
    ) {
        self.runner = runner
        self.binary = binary
        self.timeout = timeout
    }

    // MARK: - Command lines

    static let listArguments = ["agent", "list"]

    static let workspacesArguments = ["workspace", "list"]

    static let tabsArguments = ["tab", "list"]

    static func focusArguments(pane: String) -> [String] {
        ["agent", "focus", pane]
    }

    static func createTabArguments(workspace: String?, cwd: String?) -> [String] {
        var arguments = ["tab", "create"]
        if let workspace, !workspace.isEmpty { arguments += ["--workspace", workspace] }
        if let cwd, !cwd.isEmpty { arguments += ["--cwd", cwd] }
        arguments.append("--focus")
        return arguments
    }

    /// The command is one argument: herdr types it into the new pane and
    /// presses Enter, and lore runs no shell of its own.
    static func runArguments(pane: String, command: String) -> [String] {
        ["pane", "run", pane, command]
    }

    // MARK: - Calls

    /// What herdr holds right now; nil when it did not answer at all — not
    /// installed, server down, refusing, or wedged past the timeout. The first
    /// two calls have to answer: half a reading is not one, and a workspace
    /// list nobody could read would send a live chat's tab to the wrong
    /// workspace.
    ///
    /// The tab labels are the one part that may be missing on its own (#267):
    /// they name a chat on screen and nothing acts on them, so a `tab list`
    /// that did not answer leaves the chat named by what its reply stored
    /// rather than throwing away a reading that going to a chat depends on.
    func read() async -> HerdrReading? {
        guard let agents: AgentListBody = await call(Self.listArguments),
              let workspaces: WorkspaceListBody = await call(Self.workspacesArguments)
        else { return nil }
        let tabs: TabListBody? = await call(Self.tabsArguments)
        return HerdrReading(
            panes: Set(agents.result.agents.map(\.paneID)),
            workspaces: Self.labels(workspaces.result.workspaces.map { ($0.workspaceID, $0.label) }),
            tabs: Self.labels((tabs?.result.tabs ?? []).map { ($0.tabID, $0.label) })
        )
    }

    /// Ids to labels, keeping every id herdr named: a workspace or tab with no
    /// label of its own is still one herdr has, and the empty string is what
    /// stops it being printed as a name.
    private static func labels(_ pairs: [(String, String?)]) -> [String: String] {
        Dictionary(pairs.map { ($0.0, $0.1 ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// True only when herdr answered with a result of its own: a call that did
    /// nothing is never reported as one that worked.
    func focus(pane: String) async -> Bool {
        let done: OkBody? = await call(Self.focusArguments(pane: pane))
        return done != nil
    }

    /// The new tab's root pane id, or nil when the tab was not made.
    func createTab(workspace: String?, cwd: String?) async -> String? {
        let made: TabCreatedBody? = await call(Self.createTabArguments(workspace: workspace, cwd: cwd))
        return made?.result.rootPane.paneID
    }

    func run(pane: String, command: String) async -> Bool {
        let done: OkBody? = await call(Self.runArguments(pane: pane, command: command))
        return done != nil
    }

    // MARK: - Plumbing

    /// herdr's answer to one call, decoded; nil when there was none — a
    /// missing binary, a non-zero status, a kill at the timeout, or a body
    /// that carries no `result`. Every body below requires its `result`, so
    /// nothing but a decoded answer is ever read as one (`no-false-positives`
    /// rule 3: the effect is confirmed, not the attempt).
    private func call<Body: Decodable>(_ arguments: [String]) async -> Body? {
        guard let binary = binary() else { return nil }
        guard let run = await runner.run(binary, arguments: arguments, timeout: timeout),
              run.status == 0
        else { return nil }
        return try? JSONDecoder().decode(Body.self, from: Data(run.output.utf8))
    }

    /// A call whose own success is the whole answer. Every result in herdr's
    /// schema carries a `type` (protocol 19), and an error body carries no
    /// `result`, so neither a refusal nor an empty body decodes as this.
    private struct OkBody: Decodable {
        struct Result: Decodable { let type: String }
        let result: Result
    }

    private struct AgentListBody: Decodable {
        struct Result: Decodable { let agents: [Agent] }
        struct Agent: Decodable {
            let paneID: String

            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
            }
        }
        let result: Result
    }

    private struct WorkspaceListBody: Decodable {
        struct Result: Decodable { let workspaces: [Workspace] }
        struct Workspace: Decodable {
            let workspaceID: String
            /// The label the owner typed in herdr's bar (#267); herdr may name
            /// none, and then the chat is named by what its reply stored.
            let label: String?

            enum CodingKeys: String, CodingKey {
                case workspaceID = "workspace_id"
                case label
            }
        }
        let result: Result
    }

    /// `tab list`'s answer (#267). Its result carries no `type` of its own —
    /// measured 2026-09-21 — so `tabs` is what decides it is an answer.
    private struct TabListBody: Decodable {
        struct Result: Decodable { let tabs: [Tab] }
        struct Tab: Decodable {
            let tabID: String
            let label: String?

            enum CodingKeys: String, CodingKey {
                case tabID = "tab_id"
                case label
            }
        }
        let result: Result
    }

    private struct TabCreatedBody: Decodable {
        struct Result: Decodable {
            struct Pane: Decodable {
                let paneID: String
                enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
            }
            let rootPane: Pane
            enum CodingKeys: String, CodingKey { case rootPane = "root_pane" }
        }
        let result: Result
    }
}
