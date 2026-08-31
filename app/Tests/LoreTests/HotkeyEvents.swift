import AppKit
@testable import LoreKit

/// A flags-changed event as the NSEvent monitors deliver one — the modifier
/// that changed in `keyCode`, the state after the change in `flags`.
///
/// Four suites had a private copy of this factory (`LockedFnHoldTests`,
/// `DictationPauseTests`, `RecordedHotkeyTests`, `HotkeyKeyTests`), all of them
/// the same eight lines.
func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
    )!
}

/// The Fn key going down and coming up — the shape three of those four copies
/// existed to make.
func fnKeyEvent(down: Bool) -> NSEvent {
    flagsChanged(keyCode: HotkeyKey.fnKeyCode, flags: down ? [.function] : [])
}
