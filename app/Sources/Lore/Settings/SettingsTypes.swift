import AppKit
import Foundation

/// The key held to talk. Fn and Right Option are the two the app shipped with;
/// `custom` is any other key the user recorded by pressing it (#226) — the exit
/// from a Mac where macOS keeps Fn for its own features.
///
/// Only `HotkeyKey.record` builds a `custom`, and it accepts a narrow set: the
/// right-hand modifiers and the function keys that reach lore as keys. A key
/// that types, moves the cursor or is already lore's inside a dictation is
/// refused there with a reason, because a talk key has to be held down for a
/// second and a half and whatever it does the rest of the time it would keep
/// doing.
enum HotkeyKey: Hashable, Identifiable {
    case fn
    case rightOption
    case custom(keyCode: UInt16)

    var id: String { storageValue }

    var displayName: String {
        switch self {
        case .fn: Self.fnName.long
        case .rightOption: Self.rightOptionName.long
        case .custom(let keyCode): Self.name(forKeyCode: keyCode)?.long ?? "Key \(keyCode)"
        }
    }

    /// The keycap label — what fits in a chip beside another key.
    var shortName: String {
        switch self {
        case .fn: Self.fnName.short
        case .rightOption: Self.rightOptionName.short
        case .custom(let keyCode): Self.name(forKeyCode: keyCode)?.short ?? "Key"
        }
    }

    /// Check if this key matches the given flags-changed event.
    func matchesPress(_ event: NSEvent) -> Bool {
        switch self {
        case .fn:
            return event.modifierFlags.contains(.function)
        case .rightOption:
            return event.modifierFlags.contains(.option) && event.keyCode == Self.rightOptionKeyCode
        case .custom(let keyCode):
            guard let flag = Self.modifierFlags[keyCode] else { return false }
            return event.modifierFlags.contains(flag) && event.keyCode == keyCode
        }
    }

    /// True while this key arrives as a modifier — i.e. through `flagsChanged`,
    /// where `matchesPress` is the whole of the decision.
    var isModifier: Bool {
        switch self {
        case .fn, .rightOption: true
        case .custom(let keyCode): Self.modifierFlags[keyCode] != nil
        }
    }

    /// The keycode the CGEvent tap has to own end to end — non-nil only for a
    /// recorded key that is not a modifier (#226), which reaches lore as a
    /// key-down and a key-up rather than as a flag.
    var tapKeyCode: UInt16? {
        guard case .custom(let keyCode) = self, Self.modifierFlags[keyCode] == nil else {
            return nil
        }
        return keyCode
    }

    // MARK: - Storage

    /// What lands in UserDefaults. A recorded key carries its keycode, so the
    /// round trip is lossless and nothing has to be re-recorded after a launch.
    var storageValue: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "rightOption"
        case .custom(let keyCode): "\(Self.customPrefix)\(keyCode)"
        }
    }

    /// The stored string back to a key. Anything unreadable — a value from a
    /// build that offered other keys, a keycode this build refuses — is `nil`,
    /// and the store falls back to Fn rather than to a key nobody can press.
    ///
    /// Read against the *static* set (`fnRowIsStandard: true`), not the live
    /// keyboard setting: turning the F-row back into media keys after choosing
    /// F5 should leave Settings showing F5 for the user to change, not swap the
    /// talk key under them at the next launch.
    init?(storage: String) {
        switch storage {
        case "fn": self = .fn
        case "rightOption": self = .rightOption
        default:
            let digits = storage.dropFirst(Self.customPrefix.count)
            guard storage.hasPrefix(Self.customPrefix), let keyCode = UInt16(digits),
                  case .chosen(let key) = HotkeyKey.record(keyCode: keyCode, fnRowIsStandard: true),
                  key == .custom(keyCode: keyCode)
            else { return nil }
            self = key
        }
    }

    private static let customPrefix = "custom:"

    // MARK: - The recorder's verdict (#226)

    /// What the recorder makes of the key the user pressed.
    enum Recording: Equatable {
        case chosen(HotkeyKey)
        case refused(Refusal)
    }

    /// Why a key cannot be held to talk. A case rather than a string so the
    /// reason is a value the caller can branch on and the tests can name,
    /// while the copy stays in one place.
    enum Refusal: String, CaseIterable {
        case escCancels
        case spaceLocks
        case capsLockLatches
        case shortcutsUseIt
        case macOSKeepsTheMediaRow
        case itDoesSomethingElse

        /// One line the user reads once and acts on. Every one of them names
        /// the real reason and points at a key that works.
        var message: String {
            switch self {
            case .escCancels:
                "Esc cancels a recording \u{2014} try another key."
            case .spaceLocks:
                "Space locks a recording hands-free \u{2014} try another key."
            case .capsLockLatches:
                "Caps Lock stays on after you let go \u{2014} try another key."
            case .shortcutsUseIt:
                "Shortcuts use that key \u{2014} try the one on the right of the keyboard."
            case .macOSKeepsTheMediaRow:
                "macOS keeps that key for the media row \u{2014} try Right Command."
            case .itDoesSomethingElse:
                "That key already does something else \u{2014} try Right Command."
            }
        }
    }

    /// Classify a pressed key. Fn and Right Option come back as themselves:
    /// pressing one is the same act as picking it from the list.
    ///
    /// `fnRowIsStandard` is the live keyboard setting (`functionKeyRowIsStandard`)
    /// passed in rather than read here, so the classification stays a pure
    /// function of two inputs.
    static func record(keyCode: UInt16, fnRowIsStandard: Bool) -> Recording {
        switch keyCode {
        case fnKeyCode: return .chosen(.fn)
        case rightOptionKeyCode: return .chosen(.rightOption)
        case DictationEscape.keyCode: return .refused(.escCancels)
        case spaceKeyCode: return .refused(.spaceLocks)
        case capsLockKeyCode: return .refused(.capsLockLatches)
        default: break
        }
        // Right-hand modifiers: held for a moment they do nothing at all, which
        // is the whole requirement. Everything else the flag table knows is a
        // left-hand twin, and those are in almost every shortcut a Mac has —
        // holding one would start a dictation in the middle of ⌘S.
        if rightHandModifierKeyCodes.contains(keyCode) { return .chosen(.custom(keyCode: keyCode)) }
        if modifierFlags[keyCode] != nil { return .refused(.shortcutsUseIt) }

        guard functionKeyNames[keyCode] != nil else { return .refused(.itDoesSomethingElse) }
        guard fnRowIsStandard || !mediaRowKeyCodes.contains(keyCode) else {
            return .refused(.macOSKeepsTheMediaRow)
        }
        return .chosen(.custom(keyCode: keyCode))
    }

    // MARK: - Keycodes

    static let fnKeyCode: UInt16 = 63
    static let rightOptionKeyCode: UInt16 = 61
    static let capsLockKeyCode: UInt16 = 57
    static let spaceKeyCode: UInt16 = 49

    /// The three the recorder accepts. Their left-hand twins are the rest of
    /// `modifierFlags`, which is what makes that refusal derivable rather than
    /// a second hand-written list.
    static let rightHandModifierKeyCodes: Set<UInt16> = [54, 60, 62]

    /// Every modifier key and the flag it raises. Left and right are separate
    /// keycodes, which is what lets Right Option be told from Left Option in a
    /// `flagsChanged` event that carries only the shared `.option`.
    ///
    /// All ten rows are load-bearing even though only three become a `custom`:
    /// the recorder reads this table to tell a modifier's press from its
    /// release, so a key missing here could not be refused by name either.
    static let modifierFlags: [UInt16: NSEvent.ModifierFlags] = [
        54: .command, 55: .command,
        56: .shift, 60: .shift,
        58: .option, rightOptionKeyCode: .option,
        59: .control, 62: .control,
        capsLockKeyCode: .capsLock,
        fnKeyCode: .function,
    ]

    /// F1–F20, whose keycodes are in no order anyone could derive.
    static let functionKeyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20",
    ]

    /// F1–F12 double as the keyboard's media row. With "Use F1, F2, etc. as
    /// standard function keys" off — the shipping default — a bare press of one
    /// sends a system-defined media event, never a key-down, so no event tap
    /// ever sees it and a talk key set to it would simply never fire. F13 and
    /// up carry no second job and always arrive as keys.
    static let mediaRowKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
    ]

    /// System Settings › Keyboard › "Use F1, F2, etc. as standard function
    /// keys", live. Absent is the shipping default and reads as `false` —
    /// verified on this machine: the key is unset and `defaults -g` reports it
    /// missing, which is the domain named here.
    ///
    /// `CFPreferencesAppSynchronize` before the read for the same reason
    /// `FnKeySetting.current()` does it: without it the first value this
    /// process sees is served for its life.
    static var functionKeyRowIsStandard: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let stored = CFPreferencesCopyAppValue(
            "com.apple.keyboard.fnState" as CFString, kCFPreferencesAnyApplication
        )
        return stored as? Bool ?? false
    }

    // MARK: - Key names

    private static let fnName = (long: "Fn (Globe)", short: "Fn")
    private static let rightOptionName = (long: "Right Option (\u{2325})", short: "R\u{2325}")

    /// Only the three modifiers a `custom` can be built from — the rest of
    /// `modifierFlags` is refused, and Fn / Right Option carry their own names
    /// above.
    private static let rightHandModifierNames: [UInt16: (long: String, short: String)] = [
        54: ("Right Command (\u{2318})", "R\u{2318}"),
        60: ("Right Shift (\u{21E7})", "R\u{21E7}"),
        62: ("Right Control (\u{2303})", "R\u{2303}"),
    ]

    static func name(forKeyCode keyCode: UInt16) -> (long: String, short: String)? {
        if let modifier = rightHandModifierNames[keyCode] { return modifier }
        guard let function = functionKeyNames[keyCode] else { return nil }
        return (long: function, short: function)
    }
}
