import AppKit

/// Which form a dictation's items take in the app that is about to receive the
/// paste (#195). Two forms, because there are two kinds of reader: an agent
/// that can open a file by its path, and a composer that can only be handed the
/// file itself, where a path in the text is useless.
///
/// A `String` raw value so the choice can ride in a `DiagEvent` without opening
/// a free-form field (#82).
enum PasteTarget: String, Codable, Sendable, CaseIterable {
    /// A terminal, or an editor that hosts a command-line agent: an item is its
    /// absolute path in the text, and the whole dictation is one paste — the
    /// form #192 ships.
    case path
    /// Everything else — a web chat composer, a native chat app: a picture or a
    /// file travels on the pasteboard as a file, and the text names it by the
    /// filename the composer will show.
    case web

    /// The apps whose reader opens files by path. Deliberately a list of bundle
    /// ids rather than a heuristic: "can this app read a path" is not a question
    /// that can be asked of a running process, and a wrong guess costs the user
    /// the screenshot he just took.
    ///
    /// Verified on this Mac with `mdls -name kMDItemCFBundleIdentifier` where
    /// the app is installed (Terminal, Ghostty, cmux); the rest are the
    /// vendors' published ids.
    static let pathFormApps: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
        "org.alacritty",
        "com.github.wez.wezterm",
        "com.cmuxterm.app",
        "com.microsoft.VSCode",
        // Cursor ships under its Todesktop id, not a name.
        "com.todesktop.230313mzl4w4u92",
    ]

    /// The path form is the exception, so anything not on the list — including
    /// a frontmost app that reports no bundle id at all — gets the web form:
    /// an unknown app is far more likely to be a composer than a terminal, and
    /// the web form's text is still readable when the file does not attach.
    static func of(_ bundleID: String?) -> PasteTarget {
        guard let bundleID, pathFormApps.contains(bundleID) else { return .web }
        return .path
    }

    /// The app the Cmd+V is about to land in, read at paste time — the user can
    /// switch windows while the dictation is being transcribed, and what
    /// matters is where the words arrive, not where they were spoken.
    @MainActor
    static var frontmost: PasteTarget {
        of(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}
