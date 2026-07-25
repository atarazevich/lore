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
/// `IOConsoleLocked` is a sibling root property, read off the same fetch (#98).
///
/// The pid is a **hint, not an identification**: per rdar://48953777 the
/// registry records whichever app was frontmost when secure input went on,
/// which may not be the caller. Copy that names the holder must hedge
/// accordingly — and for the two processes most likely to be frontmost at grab
/// time, must not name them at all (`Attribution.misattributed`).
enum SecureInput {
    /// One reading. `active` may be true with no pid — the flag is set but no
    /// on-console session dict attributes it to a live process. That is a real,
    /// reportable state, not one to drop.
    struct State {
        let active: Bool

        /// The pid the registry attributes secure input to, reported verbatim.
        /// Suppression of a misattributed holder is a *display* rule: the raw
        /// pid still reaches the report, where the operator needs the truth.
        let pid: Int32?

        /// `IOConsoleLocked`: the console is at the lock screen. loginwindow
        /// holding secure input while this is true is the lock screen protecting
        /// the password field — working as designed, not a problem (#98).
        let consoleLocked: Bool

        /// Who the surfaces may say holds it — resolved once at `read()` so the
        /// panel, the remedy and the tests all apply one rule.
        let attribution: Attribution

        /// The raw holder name from the lookup, regardless of attribution — for
        /// the `privacy: .private` os.Logger line only, the one surface where
        /// naming a misattribution sink is safe (and how the field case was
        /// diagnosed). Every user-facing surface renders `attribution` instead;
        /// never a snapshot.
        let name: String?
    }

    /// What the user-facing surfaces may say about the holder (#98).
    enum Attribution: Equatable, Sendable {
        /// A real app to point at — as a hedged hint, per rdar://48953777.
        case app(String)
        /// No app owns the pid (a CLI or daemon holder has no
        /// `NSRunningApplication`) — the pid itself is the hint, and the case
        /// where the user most needs one (#92).
        case process(Int32)
        /// loginwindow or SecurityAgent: the registry blames whichever process
        /// was frontmost at grab time, and these two are what is frontmost when
        /// a background process grabs the flag — so neither name nor pid is
        /// shown (#98; canonical account in design §6).
        case misattributed
        /// The registry named nobody.
        case nobody
    }

    /// The single reading both consumers use (#93), so the panel and the event
    /// stream cannot disagree about whether input is withheld.
    static func read() -> State {
        let console = consoleState()
        let pid = holderPIDs(in: console.sessions).first
        let identity = pid.map(processIdentity)
        return State(
            active: isEnabled(),
            pid: pid,
            consoleLocked: console.locked,
            attribution: attribution(pid: pid, identity: identity),
            name: identity.flatMap { $0.name ?? $0.bundleID }
        )
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

    /// The live read, one registry-root fetch for both facts: `IOConsoleUsers`
    /// hangs off the root (the pid is one level down, inside the dicts), and
    /// `IOConsoleLocked` is its sibling.
    private static func consoleState() -> (sessions: [[String: Any]], locked: Bool) {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        let sessions = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] ?? []
        let locked = IORegistryEntryCreateCFProperty(
            root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool ?? false
        return (sessions, locked)
    }

    /// What the OS knows about a pid — read once per cycle in `read()` and fed
    /// to both `attribution` and the log-only `name`.
    typealias Identity = (bundleID: String?, name: String?, path: String?)

    private static func processIdentity(_ pid: Int32) -> Identity {
        let app = NSRunningApplication(processIdentifier: pid)
        return (app?.bundleIdentifier, app?.localizedName,
                app?.executableURL?.path ?? executablePath(pid))
    }

    /// The one rule for who may be named. Pure over literal identities, same
    /// doctrine as `holderPIDs(in:)`.
    static func attribution(pid: Int32?, identity: Identity?) -> Attribution {
        guard let pid else { return .nobody }
        if isMisattributionSink(bundleID: identity?.bundleID, path: identity?.path) {
            return .misattributed
        }
        if let name = identity?.name ?? identity?.bundleID { return .app(name) }
        return .process(pid)
    }

    /// loginwindow may lack an `NSRunningApplication` (the field holder was from
    /// boot, ppid 1), so the executable path is the fallback identity.
    private static func isMisattributionSink(bundleID: String?, path: String?) -> Bool {
        if bundleID == "com.apple.loginwindow" || bundleID == "com.apple.SecurityAgent" {
            return true
        }
        return path == "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[..<Int(length)].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
