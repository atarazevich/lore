import AppKit

/// What the Escape key means to a dictation (#206).
///
/// Esc used to be the discard: it deleted the audio and the entry at the
/// keypress, with nothing left to recover. But Esc is pressed for other reasons
/// — to cancel a screenshot crosshair, to close a menu — and a real dictation
/// went that way (`events.json`, 2026-08-30 12:49:46Z: a
/// `dictationDiscarded{state: recording}` five seconds after a screenshot
/// chord, with two screenshots already collected). It now pauses capture in
/// place, and a second Esc continues. No key deletes a recording.
///
/// The decision is one value rather than three branches spread across the two
/// event paths that take it, so the local monitor and the CGEvent tap cannot
/// disagree about whose key it is — and so every row of the board's logic table
/// is checkable without a crosshair on the screen.
enum DictationEscape: Equatable, Sendable {
    /// Not lore's. Passed through untouched, and never consumed.
    case passThrough
    /// Suspend capture in place — one session, one entry, one audio file.
    case pause
    /// Carry on into the same recording. The `Continue` button is this too.
    case resume

    /// Escape's own key code, in the one place the event paths read it.
    static let keyCode: UInt16 = 53

    /// The process macOS runs for the screenshot crosshair and its capture
    /// toolbar; it exists only while one of them is on screen.
    static let screenshotUIBundleID = "com.apple.screencaptureui"

    /// Whose the key is, given a dictation that is live — which the caller has
    /// already established, since it is what decides whether to take the one
    /// live reading at all. Pure, so both facts and both answers fit in one
    /// table a test can walk end to end.
    static func decide(paused: Bool, screenshotUIIsUp: Bool) -> DictationEscape {
        // The crosshair's Esc belongs to the crosshair. Consuming it would leave
        // the user unable to cancel a screenshot they are taking *into* this
        // dictation, and pausing on it would answer a key never addressed here.
        guard !screenshotUIIsUp else { return .passThrough }
        return paused ? .resume : .pause
    }

    /// The live reading: is the screenshot UI *on screen*, not merely alive.
    ///
    /// "The process is running" was the obvious test and it is wrong. Measured
    /// on this machine, 2026-08-30: `screencaptureui` had been resident for
    /// 18 h 46 m with no crosshair anywhere, and it keeps one prewarmed
    /// full-screen window on screen the whole time (alpha 1, level 24 — exactly
    /// `CGWindowLevelForKey(.mainMenuWindow)`). Either test would therefore be
    /// permanently true and Esc would never pause anything again.
    ///
    /// What is true only while the crosshair or the capture toolbar is really up
    /// is that it draws *over* the menu bar — Cmd+Shift+4 can capture the menu
    /// bar, so its window must outrank it — and that the keyboard is talking to
    /// it, which is the whole of the question "whose Esc is this". Either
    /// answers yes; the idle process answers no to both, which is what was
    /// measured.
    ///
    /// Read only once a recording makes the question worth asking: this walks
    /// every running application and every on-screen window, and an Esc outside
    /// a dictation never gets this far.
    ///
    /// Should both readings miss a live crosshair, the cost is that Esc pauses
    /// the dictation and the crosshair keeps the key — the behaviour before this
    /// issue, minus the destruction, which is the part that mattered.
    ///
    /// Unverified, and only a live window can settle it: the floating thumbnail
    /// left on screen for a few seconds after a capture is this process's window
    /// too. The comparison is strict — *above* the menu bar, not at it — so a
    /// thumbnail sitting at or below that level is correctly ignored; if it
    /// turns out to sit above, Esc will pass through for the seconds it lingers
    /// and the dictation simply carries on. Nobody could measure it headless
    /// (raising a crosshair needs the screen), so the verdict is by use.
    @MainActor
    static var screenshotUIIsUp: Bool {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == screenshotUIBundleID }) else { return false }
        if app.isActive { return true }
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return windows.contains { window in
            (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier
                && ((window[kCGWindowLayer as String] as? NSNumber)?.int32Value ?? 0)
                    > CGWindowLevelForKey(.mainMenuWindow)
        }
    }
}
