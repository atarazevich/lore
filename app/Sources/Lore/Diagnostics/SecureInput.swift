import AppKit
import Carbon
import IOKit

/// Secure-input state, read one way by everyone who asks.
///
/// While secure input is on, no app receives keystrokes and every CGEvent tap is
/// starved — the prime suspect for "permissions granted, Fn dead".
/// `IsSecureEventInputEnabled()` answers that for *our* session and is the only
/// thing `active` rests on. The holding pid is a separate, weaker signal, and it
/// is nested: `IOConsoleUsers` is a property of the IORegistry **root**, while
/// `kCGSSessionSecureInputPID` lives *inside* the per-session dicts of that
/// array (Apple's `IOKitKeysPrivate.h` lists the two under disjoint headings).
/// Reading the pid key off the root returns nil unconditionally (#92).
///
/// The pid is a **hint, not an identification**: per rdar://48953777 an app that
/// enables secure input while inactive is recorded as whichever app happened to
/// be frontmost. Copy that names the holder must hedge accordingly.
enum SecureInput {
    /// One reading. `active` may be true with no pid — the flag is set but no
    /// on-console session dict attributes it to a live process. That is a real,
    /// reportable state, not one to drop.
    struct State {
        let active: Bool

        /// The pid the registry attributes secure input to, reported verbatim —
        /// SecurityAgent's included, so `holderPID: null` in a report keeps one
        /// meaning: the registry named nobody.
        let pid: Int32?

        /// The holder's display name. It identifies software the user runs, so
        /// it is machine-local: panel and `os.Logger` only, never a snapshot.
        var name: String? { pid.flatMap { holderName(pid: $0) } }
    }

    /// The single reading both consumers use (#93), so the panel and the event
    /// stream cannot disagree about whether input is withheld.
    static func read() -> State {
        State(active: isEnabled(), pid: holderPIDs(in: consoleUsers()).first)
    }

    /// The system-wide secure-input flag, and the authority on `active`: it is
    /// scoped to our own session and answers exactly the question asked — are
    /// *our* keystrokes being withheld. The registry pid never gets a vote.
    private static func isEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// Which pids the registry attributes secure input to. Pure over the session
    /// dicts so it is testable off literals; the registry read itself is live-only.
    ///
    /// Only sessions on the console count: under fast user switching a background
    /// user's password prompt puts a pid in *their* session dict, and that holder
    /// is starving their keyboard, not ours. Every on-console session is walked —
    /// the holder need not be in the first. `pid <= 0` is not a process.
    static func holderPIDs(in sessions: [[String: Any]]) -> [Int32] {
        sessions
            .filter { $0["kCGSSessionOnConsoleKey"] as? Bool == true }
            .compactMap { $0["kCGSSessionSecureInputPID"] as? Int32 }
            .filter { $0 > 0 }
    }

    /// The live read. `IOConsoleUsers` hangs off the registry root; the pid is
    /// one level down, inside the dicts.
    private static func consoleUsers() -> [[String: Any]] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let prop = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        ) else { return [] }
        return prop.takeRetainedValue() as? [[String: Any]] ?? []
    }

    /// The holder's display name — machine-local, never persisted into a snapshot.
    ///
    /// `nil` for `com.apple.SecurityAgent`: the system's own password prompt doing
    /// exactly its job is recognized rather than offered up as a culprit. Only the
    /// blame is withheld — `active` still stands and the pid still reaches the
    /// report.
    static func holderName(
        pid: Int32,
        lookup: (Int32) -> (bundleID: String?, localizedName: String?) = {
            let app = NSRunningApplication(processIdentifier: $0)
            return (app?.bundleIdentifier, app?.localizedName)
        }
    ) -> String? {
        let app = lookup(pid)
        guard app.bundleID != "com.apple.SecurityAgent" else { return nil }
        return app.localizedName ?? app.bundleID
    }
}
