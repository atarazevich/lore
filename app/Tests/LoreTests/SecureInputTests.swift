import IOKit
import XCTest
@testable import LoreKit

/// #92: `kCGSSessionSecureInputPID` was read as a property of the IORegistry
/// **root**, where it does not exist. It lives one level down, inside the dicts
/// of the root's `IOConsoleUsers` array — so the old lookup returned "nobody
/// holds secure input" on every machine, forever, and the field reports that
/// said `holderPID: null` were the probe failing, not evidence of no holder.
final class SecureInputTests: XCTestCase {

    private let pidKey = "kCGSSessionSecureInputPID"

    /// A session dict as the registry hands it over.
    private func session(pid: Int32?, onConsole: Bool = true) -> [String: Any] {
        var dict: [String: Any] = ["kCGSSessionOnConsoleKey": onConsole]
        if let pid { dict[pidKey] = NSNumber(value: pid) }
        return dict
    }

    /// The structural fact the bug was built on, pinned against the live
    /// registry: the pid key is absent from the root, while `IOConsoleUsers` is
    /// present there and really does bridge to the `[[String: Any]]` that
    /// `holderPIDs(in:)` walks. This pins the *shape* only — it cannot catch the
    /// old lookup, which read nil off the root exactly as this asserts. Whether a
    /// holder is active right now goes unasserted too: finding out would mean
    /// starving this machine's keyboard.
    func testPIDKeyIsNotARootPropertyAndConsoleUsersBridgesToSessionDicts() throws {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }

        let rootPID = IORegistryEntryCreateCFProperty(
            root, pidKey as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        XCTAssertNil(rootPID, "\(pidKey) is a console-user-dict key, never a root property")

        let users = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        try XCTSkipIf(users == nil, "no IOConsoleUsers (headless) — nothing to walk")
        let sessions = try XCTUnwrap(users as? [[String: Any]], "IOConsoleUsers is the root array of session dicts")
        try XCTSkipIf(sessions.isEmpty, "no console session (headless) — nothing to walk")
        XCTAssertTrue(
            sessions.contains { $0["kCGSSessionOnConsoleKey"] as? Bool == true },
            "the session dicts really do carry the console flag the walk filters on"
        )
    }

    /// A machine can host several sessions and the holder need not be in the
    /// first, so every session is walked rather than `first` being taken.
    func testEverySessionIsWalkedNotJustTheFirst() {
        let sessions = [session(pid: nil), session(pid: 501), session(pid: 900)]
        XCTAssertEqual(SecureInput.holderPIDs(in: sessions), [501, 900])
    }

    /// Under fast user switching another user's password prompt holds *their*
    /// keyboard, not ours; their pid must not be offered as ours.
    func testSessionsOffTheConsoleAreSkipped() {
        let sessions = [session(pid: 77, onConsole: false), session(pid: 88)]
        XCTAssertEqual(SecureInput.holderPIDs(in: sessions), [88])
    }

    /// `pid <= 0` names no process; it is the registry's way of saying nothing.
    func testNonProcessPIDsAreSkipped() {
        let sessions = [session(pid: 0), session(pid: -1), session(pid: 42)]
        XCTAssertEqual(SecureInput.holderPIDs(in: sessions), [42])
    }

    /// No key at all is the common case: secure input off.
    func testSessionsWithoutTheKeyYieldNoHolder() {
        XCTAssertTrue(SecureInput.holderPIDs(in: [session(pid: nil)]).isEmpty)
    }

    /// SecurityAgent holding the keyboard *is* the password prompt working. It is
    /// recognized rather than blamed: no name for the panel to accuse, while the
    /// pid still reaches the report unambiguously and `read()` still reports
    /// secure input active off the flag.
    func testSecurityAgentIsRecognizedRatherThanBlamedButItsPIDStillReports() {
        XCTAssertNil(SecureInput.holderName(pid: 77, lookup: { _ in ("com.apple.SecurityAgent", "SecurityAgent") }))
        XCTAssertEqual(SecureInput.holderName(pid: 88, lookup: { _ in ("com.1password.1password", "1Password") }), "1Password")
        XCTAssertEqual(SecureInput.holderPIDs(in: [session(pid: 77)]), [77])
    }
}
