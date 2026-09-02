import AppKit

/// What the Escape key means to a dictation (#206, #233).
///
/// Esc was the discard once: it deleted the audio and the entry at the
/// keypress, with nothing left to recover. #206 made it pause capture in place,
/// and a second Esc continue. That is retired (2026-09-02, #233): a pause the
/// eye can miss costs whole minutes of speech — 76 s and 49 s spoken into a
/// stopped microphone on 2026-09-01, and a held Esc flipping pause and resume
/// at the key-repeat rate — while the key itself was being pressed to *stop*.
/// So Esc cancels: the dictation ends without pasting, the entry lands in
/// history with its audio, its words and its items, and the bubble says so on
/// its way out. "You hit escape when you want to stop and you don't want to use
/// the recording — that's like 90% of the time." The pause moved to the talk
/// key (`HotkeyManager.SpaceAction`).
///
/// No key deletes a recording, with the two edges that promise has always had.
/// A dictation under the half-second minimum with nothing collected is
/// abandoned as it always was (#182/#229's slip rule) and shows no face —
/// there is no entry there for `— in history` to point at, and saying so would
/// be a lie. And Fn+R / Fn+Q still reach `discardRecording` (`HotkeyManager`),
/// because reading aloud and recording are one gesture on one key: a
/// pre-existing exception, untouched here.
///
/// This type is the crosshair reading and Escape's keycode, and nothing else.
/// Whose the key is, is one Bool at the caller (`HotkeyManager.escapeIsOurs`),
/// read by both event paths so the local monitor and the CGEvent tap cannot
/// disagree about it.
enum DictationEscape {
    /// Escape's own key code, in the one place the event paths read it.
    static let keyCode: UInt16 = 53

    /// The process macOS runs for the screenshot crosshair and its capture
    /// toolbar; it exists only while one of them is on screen.
    static let screenshotUIBundleID = "com.apple.screencaptureui"

    /// The live reading: is the screenshot UI *on screen*, not merely alive.
    ///
    /// "The process is running" was the obvious test and it is wrong. Measured
    /// on this machine, 2026-08-30: `screencaptureui` had been resident for
    /// 18 h 46 m with no crosshair anywhere, and it keeps one prewarmed
    /// full-screen window on screen the whole time (alpha 1, level 24 — exactly
    /// `CGWindowLevelForKey(.mainMenuWindow)`). Either test would therefore be
    /// permanently true and Esc would never reach a dictation again.
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
    /// Should both readings miss a live crosshair, the cost is that the
    /// dictation is cancelled into history and the crosshair keeps the key: one
    /// re-record, and nothing lost — which is why #233 could leave this reading
    /// exactly as #206 drew it.
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
