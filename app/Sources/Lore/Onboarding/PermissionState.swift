import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

/// The three grants the required set of onboarding collects, in the order the
/// board reveals them.
enum RequiredGrant: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    /// SF Symbol in the card's 28pt icon tile.
    var icon: String {
        switch self {
        case .microphone: return "mic"
        case .accessibility: return "figure.wave"
        case .inputMonitoring: return "keyboard"
        }
    }

    /// The two concrete promises under "lore needs this to:" — what the grant
    /// buys the user, not what the API is called.
    var reasons: [String] {
        switch self {
        case .microphone:
            return ["Hear you when you hold the key.", "Nothing is recorded until you do."]
        case .accessibility:
            return ["Type your words at the cursor, in any app.", "Read the key you hold."]
        case .inputMonitoring:
            return ["Feel the Fn key even when \(LoreTheme.wordmark) is in the background.",
                    "Keep hold-to-talk alive while another app has focus."]
        }
    }

    /// The pane the button opens, and the name this grant carries in the event
    /// stream. Identity by raw value: `SettingsPane` and `DiagEvent.Permission`
    /// spell all three the same way, pinned by `OnboardingStateTests`.
    var pane: SettingsPane { SettingsPane(rawValue: rawValue)! }
    var diagPermission: DiagEvent.Permission { DiagEvent.Permission(rawValue: rawValue)! }

    /// Board 2a: the microphone card carries the one caption that has to tell
    /// the truth about a button whose label never changes.
    var caption: String? {
        switch self {
        case .microphone:
            return "First time, macOS asks. After that, this button opens System Settings \u{203A} Privacy & Security."
        case .accessibility, .inputMonitoring:
            return nil
        }
    }
}

/// All three grants read at one instant. Every green in the flow is derived
/// from one of these at presentation time, never latched
/// (`.claude/rules/no-false-positives.md` §1–2).
struct PermissionSnapshot: Equatable, Sendable {
    var microphone = false
    var accessibility = false
    var inputMonitoring = false

    /// True when macOS has never asked about the microphone — the only state in
    /// which the native prompt can still appear.
    var microphoneUndetermined = true

    subscript(grant: RequiredGrant) -> Bool {
        switch grant {
        case .microphone: return microphone
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        }
    }

    var allGranted: Bool { RequiredGrant.allCases.allSatisfy { self[$0] } }

    /// The card the flow is waiting on: the first ungranted one in board order.
    /// `nil` once the required set is complete.
    var current: RequiredGrant? { RequiredGrant.allCases.first { !self[$0] } }

    /// A granted card and the one the flow is waiting on are live; the rest are
    /// 50%-opacity locked stubs (board 2a). Dimming a grant the user actually
    /// holds would be a claim about it that is not true, so green stays live.
    func isRevealed(_ grant: RequiredGrant) -> Bool { self[grant] || grant == current }
}

/// The app's TCC reads — every surface that reports a grant asks through here,
/// so no two can disagree about one permission (`no-false-positives.md` §2).
/// Each is a syscall or an IPC round trip, and `AXIsProcessTrusted()` can block
/// for hundreds of milliseconds: main-RunLoop callers get a frozen window.
enum PermissionReader {

    /// One reading of all three. Nonisolated on purpose: the caller owns the
    /// queue this runs on.
    static func snapshot() -> PermissionSnapshot {
        let mic = MicrophonePermission.status
        return PermissionSnapshot(
            microphone: mic == .authorized,
            accessibility: accessibilityGranted(),
            inputMonitoring: inputMonitoringGranted(),
            microphoneUndetermined: mic == .notDetermined
        )
    }

    static func accessibilityGranted() -> Bool { AXIsProcessTrusted() }

    /// `CGPreflightListenEventAccess()` answers from a per-process cache: once it
    /// has returned false, a grant made during the System Settings round trip is
    /// invisible for the rest of the process's life, which is what made the old
    /// onboarding tell the user to relaunch. `IOHIDCheckAccess` asks hidd every
    /// call, so it *does* see the new grant. Either one saying granted wins — a
    /// positive is never downgraded, and if a future macOS reverses which of the
    /// two is stale, the honest answer still gets through.
    static func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            || CGPreflightListenEventAccess()
    }
}
