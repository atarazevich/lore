import Foundation

/// The Copying section's switches (#198), and the one place their UserDefaults
/// keys and defaults are written down.
///
/// Two kinds of reader, one table. The Settings card binds through
/// `SettingsStore`, which writes these keys; the surfaces that hold no settings
/// object — the clipboard door, the paste's own text, the event tap — read them
/// here, live, at the moment they act. Live is the contract: a switch changes
/// the next dictation with no restart, and nothing caches a copy across one.
enum RichInputSettings {
    /// Every switch in the section, with its key and the value a machine that
    /// has never opened the section behaves as.
    enum Switch: String, CaseIterable, Sendable {
        /// The master switch — the same one the bubble's paperclip is.
        case collect
        case text
        case images
        case files
        /// Whether Fn+S and the system-shortcut redirect are live at all.
        case screenshots
        /// Whether inserted material is marked in the pasted text.
        case tags
        /// While recording, Cmd+Shift+3/4 behave like Fn+S (#199).
        case redirectSystemScreenshot

        var key: String { "richInput.\(rawValue)" }

        /// Files are off: a path is rarely what the target of a prompt wants,
        /// and a Finder copy is the one kind that happens by accident.
        /// Everything else is on — the feature is the default behaviour.
        var defaultValue: Bool { self == .files ? false : true }
    }

    /// The size ceiling for the collected PNGs (#196). 0 is the unlimited
    /// sentinel, the same as the audio retention setting's ∞.
    static let keepMegabytesKey = "richInput.keepMB"

    /// 200 MB. Dictation recordings are capped by *count* (`DictationHistory.
    /// audioRetentionLimit`, 500 newest), so there is no megabyte figure to
    /// mirror — what is mirrored is the rule's shape: newest kept, oldest
    /// deleted, pruned at write time, 0 = unlimited.
    static let defaultKeepMegabytes = 200

    // MARK: - Live reads

    /// The defaults the app booted with. `AppContainer` points this at its own
    /// store (a UI-test run gets a suite, not the user's), so every read here
    /// sees exactly what the Settings card wrote. `.standard` until then, which
    /// is what a live launch uses anyway.
    nonisolated(unsafe) private static var store: UserDefaults = .standard

    static func use(_ defaults: UserDefaults) { store = defaults }

    /// Pure read, so the whole table is testable against a temporary store.
    static func isOn(_ item: Switch, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: item.key) as? Bool ?? item.defaultValue
    }

    static func isOn(_ item: Switch) -> Bool { isOn(item, in: store) }

    /// Every switch resolved at once — what `SettingsStore` seeds its card
    /// state from.
    static func all(in defaults: UserDefaults) -> [Switch: Bool] {
        Dictionary(uniqueKeysWithValues: Switch.allCases.map { ($0, isOn($0, in: defaults)) })
    }

    /// The seam `DictationItem.pasteText` reads (#198): with it off, an item is
    /// pasted bare — copied text as a plain paragraph, a screenshot as its
    /// path — with no marker around it.
    static var tagsEnabled: Bool { isOn(.tags) }

    /// Whether Lore takes a screenshot at all (#198): Fn+S, and the
    /// Cmd+Shift+3/4 redirect that rides on the same switch (#199).
    ///
    /// The master switch is half of it (#202). With collecting off the picture
    /// has nowhere to land — the door would refuse it — so Lore must not take
    /// one: Cmd+Shift+3/4 go wherever the user already has them configured, and
    /// Fn+S does nothing. Standing in front of a system shortcut only to discard
    /// what it produced is the one outcome where the screenshot exists nowhere.
    static var screenshotsEnabled: Bool { isOn(.collect) && isOn(.screenshots) }

    /// Whether a system screenshot taken during a dictation goes to the prompt
    /// (#199). Only ever asked while `screenshotsEnabled`.
    static var redirectsSystemScreenshot: Bool { isOn(.redirectSystemScreenshot) }

    static func keepMegabytes(in defaults: UserDefaults) -> Int {
        defaults.object(forKey: keepMegabytesKey) as? Int ?? defaultKeepMegabytes
    }

    static var keepMegabytes: Int { keepMegabytes(in: store) }

    // MARK: - Kinds

    /// Which switch owns a kind. A copied link is text — it is words on the
    /// clipboard, and the section offers pictures and files, not addresses.
    static func owner(of kind: DictationItemKind) -> Switch {
        switch kind {
        case .text, .url: .text
        case .image: .images
        case .fileURL: .files
        }
    }

    /// Whether the door may collect this kind at all: the master switch and the
    /// kind's own. A switched-off kind produces no item and no count.
    static func collects(_ kind: DictationItemKind, in defaults: UserDefaults) -> Bool {
        isOn(.collect, in: defaults) && isOn(owner(of: kind), in: defaults)
    }

    static func collects(_ kind: DictationItemKind) -> Bool { collects(kind, in: store) }
}
