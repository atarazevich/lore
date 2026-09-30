import Foundation

/// What the sending shell reads from herdr about its own pane (#257, #267):
/// what the chat is about, and the labels on the workspace and tab it sits in.
///
/// Every field stands on its own. herdr may name a tab and not a workspace, or
/// a pane and no title, and an absent field is absent rather than filled in.
public struct HerdrPaneFacts: Equatable, Sendable {
    /// The terminal title as the terminal set it, spinner and all.
    public var title: String?
    public var workspaceLabel: String?
    public var tabLabel: String?

    public init(title: String? = nil, workspaceLabel: String? = nil, tabLabel: String? = nil) {
        self.title = title
        self.workspaceLabel = workspaceLabel
        self.tabLabel = tabLabel
    }
}

/// The herdr CLI as both ends of the wire reach it (#257, #258): where its
/// binary is, and the one call `lore say` makes before it sends a reply.
///
/// Shared because the command and the app resolve the same binary. The app also
/// makes six calls of its own (`HerdrClient`), which stay there; herdr's schema
/// lives on this side of the wire so neither end invents its own.
public enum Herdr {

    /// Where the CLI is looked for, in order. The command runs in the agent's
    /// own shell, where PATH would usually do, but a shell started by something
    /// else (an editor's task runner, a launch agent) may not carry it — and the
    /// app, launched from Finder, never does.
    public static var searchPaths: [String] {
        [
            NSHomeDirectory() + "/.local/bin/herdr",
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
        ]
    }

    /// Nil when herdr is not installed. Re-resolved per call: it may be
    /// installed while lore runs.
    public static func resolveBinary() -> URL? {
        searchPaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// `herdr api snapshot` — the one call `lore say` makes.
    ///
    /// One call and not three (#267). The title, the tab label and the
    /// workspace label live in three different answers — `agent get`, `tab get`,
    /// `workspace get` — and the snapshot carries all three in the shapes those
    /// answers use, so asking once costs 8 ms against the 5 ms `agent get`
    /// alone cost before (measured 2026-09-21) and the three facts come from one
    /// instant rather than three. It is part of herdr's published API, not a
    /// debug dump: `herdr api schema` declares it.
    public static let snapshotArguments = ["api", "snapshot"]

    /// What that snapshot says about one pane; nil when the body did not decode
    /// at all, which is herdr not answering.
    ///
    /// The labels are looked up by the ids the *reply* will carry, so what is
    /// stored beside a reply and what the player later reads live by the same
    /// ids can never be about two different tabs. herdr's own ids for the pane
    /// stand in when the shell set none.
    public static func paneFacts(
        from data: Data, pane: String, tab: String?, workspace: String?
    ) -> HerdrPaneFacts? {
        guard let body = try? JSONDecoder().decode(SnapshotBody.self, from: data) else { return nil }
        let snapshot = body.result.snapshot
        let agent = snapshot.agents.first { $0.paneID == pane }
        let tabID = tab ?? agent?.tabID
        let workspaceID = workspace ?? agent?.workspaceID
        return HerdrPaneFacts(
            title: agent?.title,
            workspaceLabel: workspaceID.flatMap { id in
                snapshot.workspaces.first { $0.workspaceID == id }?.label
            },
            tabLabel: tabID.flatMap { id in snapshot.tabs.first { $0.tabID == id }?.label }
        )
    }

    /// herdr's live snapshot, of which lore reads three fields. Every element
    /// has the shape its own `… list` answer has, so neither end of the wire
    /// learns a second schema.
    private struct SnapshotBody: Decodable {
        struct Result: Decodable { let snapshot: Snapshot }
        struct Snapshot: Decodable {
            let agents: [Agent]
            let tabs: [Tab]
            let workspaces: [Workspace]
        }
        struct Agent: Decodable {
            let paneID: String
            let tabID: String?
            let workspaceID: String?
            let title: String?

            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
                case tabID = "tab_id"
                case workspaceID = "workspace_id"
                case title = "terminal_title_stripped"
            }
        }
        struct Tab: Decodable {
            let tabID: String
            let label: String?

            enum CodingKeys: String, CodingKey {
                case tabID = "tab_id"
                case label
            }
        }
        struct Workspace: Decodable {
            let workspaceID: String
            let label: String?

            enum CodingKeys: String, CodingKey {
                case workspaceID = "workspace_id"
                case label
            }
        }
        let result: Result
    }
}
