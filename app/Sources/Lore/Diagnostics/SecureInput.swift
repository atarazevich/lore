import AppKit
import Carbon
import IOKit

/// Secure-input state, read two independent ways.
///
/// `isEnabled()` is the public boolean API (`IsSecureEventInputEnabled`) that
/// *nothing checked before #83* — a prime suspect for "permissions granted, Fn
/// dead", because while it is on no app receives keystrokes and every CGEvent
/// tap is starved. `holder()` reads the holding pid from the IOKit registry so
/// the panel can name the offending process.
///
/// Extracted here so the health probe and `HotkeyManager`'s 5-second monitor
/// read the registry the same way instead of keeping two copies.
enum SecureInput {
    /// The system-wide secure-input flag. `true` means keystrokes are being
    /// withheld from every app.
    static func isEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// The pid holding secure input, if any. `active` can be true with a `nil`
    /// pid when the flag is set but no process advertises ownership.
    static func holder() -> (active: Bool, pid: Int32?) {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard let prop = IORegistryEntryCreateCFProperty(
            root, "kCGSSessionSecureInputPID" as CFString, kCFAllocatorDefault, 0
        ) else {
            IOObjectRelease(root)
            return (false, nil)
        }
        IOObjectRelease(root)
        if let pid = prop.takeRetainedValue() as? Int32, pid > 0 {
            return (true, pid)
        }
        return (false, nil)
    }

    /// The holder's display name — identifies software the user runs, so it is
    /// machine-local: shown in the panel, never persisted into a snapshot.
    static func holderName(pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
