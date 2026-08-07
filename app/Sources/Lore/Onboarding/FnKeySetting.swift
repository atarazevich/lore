import Foundation

/// What macOS currently does when the Fn / 🌐 key is pressed — System Settings
/// › Keyboard › "Press 🌐 fn key to". Anything but `doNothing` swallows the key
/// before `HotkeyManager` can see the hold. Raw values are `AppleFnUsageType`;
/// see `docs/features/onboarding.md` for the domain and the empirical check.
enum FnKeyAction: Int, Equatable, Sendable, CaseIterable {
    case doNothing = 0
    case changeInputSource = 1
    case showEmojiPicker = 2
    case startDictation = 3
    /// A value this build does not know — a future macOS adding a fifth item.
    case unknown = -1

    /// What the live readout says lore sees, in the wording of the System
    /// Settings menu item so the user compares like with like. `unknown` names
    /// no item: claiming a setting the user does not have is a false reading.
    var label: String {
        switch self {
        case .doNothing: return "Do Nothing"
        case .changeInputSource: return "Change Input Source"
        case .showEmojiPicker: return "Show Emoji & Symbols"
        case .startDictation: return "Start Dictation"
        case .unknown: return "an unrecognized setting"
        }
    }

    /// `doNothing` is the only value that leaves the key for lore.
    var conflictsWithHotkey: Bool { self != .doNothing }
}

enum FnKeySetting {

    static let domain = "com.apple.HIToolbox"
    static let key = "AppleFnUsageType"

    /// The macOS shipping default when the user has never touched the setting —
    /// the emoji picker, which is exactly the behaviour that eats the hold.
    static let systemDefault = FnKeyAction.showEmojiPicker

    /// Map a stored value to an action. `nil` is the never-set case; anything
    /// unrecognized is `.unknown`, which conflicts — skipping the step on a
    /// value we do not understand would leave a key that never reaches lore.
    static func action(forStored stored: Int?) -> FnKeyAction {
        guard let stored else { return systemDefault }
        return FnKeyAction(rawValue: stored) ?? .unknown
    }

    /// Read the setting as it is *now*. `CFPreferencesAppSynchronize` is
    /// load-bearing: without it the first value this process reads is served for
    /// its life, and the step would never notice the user changing it.
    ///
    /// Nonisolated — called from the poller's background queue like the TCC reads.
    static func current() -> FnKeyAction {
        CFPreferencesAppSynchronize(domain as CFString)
        let stored = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int
        return action(forStored: stored)
    }
}
