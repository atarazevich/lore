import CoreGraphics

/// The two screenshot shortcuts lore stands in for while a dictation records
/// (#199): the user's own habit reaches the prompt, because the clipboard
/// variant lore posts instead is the only one lore can see.
///
/// Pure, so the decision is testable without an event tap.
enum ScreenshotShortcut: Equatable {
    /// Cmd+Shift+4 — drag a region.
    case region
    /// Cmd+Shift+3 — the whole screen.
    case wholeScreen

    /// Which shortcut a key-down is, if either.
    ///
    /// Bare Cmd+Shift only: a real key-down also carries device-level bits, so
    /// the comparison is against the modifier keys alone, and the Ctrl variant
    /// the user typed themselves is deliberately not one of these — it already
    /// puts the picture on the clipboard, and consuming it would post it twice.
    init?(keyCode: Int64, flags: CGEventFlags) {
        guard flags.intersection(Self.modifierKeys) == [.maskCommand, .maskShift] else {
            return nil
        }
        switch keyCode {
        case 21: self = .region // '4'
        case 20: self = .wholeScreen // '3'
        default: return nil
        }
    }

    var isFullScreen: Bool { self == .wholeScreen }

    private static let modifierKeys: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn,
    ]
}
