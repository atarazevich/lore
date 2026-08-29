import AppKit
import os

/// Marks the key events Lore itself synthesizes (paste's Cmd+V/Z, Read Aloud's
/// Cmd+C) so the session tap can tell them from the user's (#140). Without the
/// marker, Lore's own Cmd+V arrived at its own tap and stamped `lastTapKeyDown`
/// — self-generated "evidence" that the tap is fed, which silently acknowledged
/// the #135 signing migration and reset the starvation measurement.
enum SyntheticKeyEvent {
    /// Rides in `.eventSourceUserData`, which synthetic sources carry through
    /// to taps and real HID events never set. "Lore" in ASCII.
    ///
    /// The OS-native alternative (`.eventSourceUnixProcessID == getpid()` in
    /// the tap) was rejected for lack of a verifiable negative: every CGEvent
    /// created in-process carries our pid in that field (even with a nil
    /// source), and whether hardware key-downs arrive at the tap with a
    /// different value cannot be pinned in a test — a listen tap needs Input
    /// Monitoring and posting real events would type into the user's session.
    /// Misclassifying a real key-down as ours would drop Space-lock/Esc
    /// handling entirely, so the explicit marker stays.
    private static let marker: Int64 = 0x4C6F_7265

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}

/// The change counts of lore's own pasteboard writes (#192). The clipboard door
/// polls `changeCount` while a dictation records, and a paste — plus the restore
/// 800 ms behind it — moves that counter twice. Without this, lore's own paste
/// would come back as material for the next dictation.
///
/// `@unchecked Sendable`: every access is behind the lock. `TextInserter` writes
/// from wherever a paste is scheduled; `ClipboardWatcher` reads on the main
/// actor.
final class PasteboardWriteLedger: @unchecked Sendable {
    static let shared = PasteboardWriteLedger()

    private let lock = NSLock()
    /// Bounded: a change count is interesting for the seconds around the write
    /// that made it, and the poll it must beat runs every 100 ms.
    private var counts: [Int] = []
    private static let capacity = 8

    func note(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        counts.append(count)
        if counts.count > Self.capacity { counts.removeFirst(counts.count - Self.capacity) }
    }

    func isOurs(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return counts.contains(count)
    }
}

enum TextInserter {
    private static let log = Logger(subsystem: "com.lore.app", category: "TextInserter")

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func paste(_ text: String) {
        let granted = isAccessibilityGranted

        // Even if AXIsProcessTrusted returns false, try the paste anyway —
        // macOS sometimes caches the result and requires a restart to update.
        // The clipboard will still be set, so at worst the user can Cmd+V manually.
        if !granted {
            log.error("accessibility reports false — attempting paste anyway")
        }

        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let savedItems = savePasteboard(pasteboard)

        // Set our text
        writeString(text, to: pasteboard)

        // Small delay to let clipboard settle, then simulate Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // `postCmdV` reports only whether the CGEvents could be *created*.
            // `CGEvent.post` returns nothing, so whether the paste reached an app is
            // unobservable from here — an `Outcome.ok` would have read "fine" in
            // precisely the incident this feature exists to diagnose.
            let eventsCreated = postCmdV()
            DiagStore.record(.pasteAttempt(
                kind: .paste,
                eventsCreated: eventsCreated,
                accessibilityTrusted: granted
            ))

            // Restore clipboard after target app processes the paste
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                restorePasteboard(NSPasteboard.general, items: savedItems)
                log.debug("clipboard restored")
            }
        }
    }

    /// Undo the previous paste (Cmd+Z), then paste new text (Cmd+V).
    /// Used by the upgrade flow to replace previously pasted text.
    static func undoAndPaste(_ text: String) {
        let granted = isAccessibilityGranted

        if !granted {
            log.error("accessibility reports false — attempting undo+paste anyway")
        }

        let pasteboard = NSPasteboard.general
        let savedItems = savePasteboard(pasteboard)

        // Set new text first
        writeString(text, to: pasteboard)

        // Cmd+Z to undo previous paste, then Cmd+V to paste new text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let undone = postCmdZ()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let eventsCreated = undone && postCmdV()
                DiagStore.record(.pasteAttempt(
                    kind: .undoAndPaste,
                    eventsCreated: eventsCreated,
                    accessibilityTrusted: granted
                ))

                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    restorePasteboard(NSPasteboard.general, items: savedItems)
                    log.debug("clipboard restored")
                }
            }
        }
    }

    /// Returns whether the synthetic key events could be *created*. Posting is
    /// fire-and-forget: `CGEvent.post` has no return value and no delivery receipt.
    ///
    /// Uses cghidEventTap — more reliable for posting synthetic events to other apps.
    /// cgSessionEventTap is better for *reading* events; cghidEventTap injects at the
    /// HID level which the frontmost app reliably receives.
    ///
    /// `flags` defaults to Command alone — every chord here was one until the
    /// screenshot key (#192), which is the system's own Ctrl+Shift+Cmd+4.
    @discardableResult
    private static func postCommandChord(
        _ virtualKey: CGKeyCode, flags: CGEventFlags = .maskCommand
    ) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            log.error("Failed to create CGEvent for Cmd chord (key \(virtualKey))")
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        // Our own chord must not count as tap-liveness evidence (#140).
        SyntheticKeyEvent.mark(keyDown)
        SyntheticKeyEvent.mark(keyUp)
        keyDown.post(tap: .cghidEventTap)
        usleep(20_000) // 20ms between key down and up for reliable delivery
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    private static func postCmdZ() -> Bool { postCommandChord(0x06) } // 6 = 'Z'

    @discardableResult
    private static func postCmdV() -> Bool { postCommandChord(0x09) } // 9 = 'V'

    @discardableResult
    private static func postCmdC() -> Bool { postCommandChord(0x08) } // 8 = 'C'

    /// Press the system's "copy selected area to clipboard" shortcut for the
    /// user (#192): the familiar crosshair appears, the drag lands a PNG on the
    /// clipboard with no file and no thumbnail delay, and the clipboard door
    /// picks it up at the second it happened.
    @discardableResult
    static func postScreenshotToClipboard() -> Bool {
        let created = postCommandChord(0x15, flags: [.maskCommand, .maskShift, .maskControl]) // 21 = '4'
        DiagStore.record(.dictationScreenshotChord(eventsCreated: created))
        return created
    }

    // MARK: - Selection capture (Read Aloud, #105)

    /// Capture the frontmost app's selection via synthesized ⌘C, preserving
    /// the user's clipboard. The clipboard is restored as soon as the text is
    /// read — nothing waits on a paste here, unlike the 800 ms paste flow.
    /// When nothing (or only whitespace) was copied — no selection, or the
    /// app ignored the chord — falls back to the restored clipboard contents
    /// (#106). Returns nil only when both yield nothing.
    @MainActor
    static func copySelection() async -> (text: String, fromClipboard: Bool)? {
        let pasteboard = NSPasteboard.general
        let savedItems = savePasteboard(pasteboard)

        pasteboard.clearContents()
        let clearedCount = pasteboard.changeCount
        PasteboardWriteLedger.shared.note(clearedCount)
        _ = postCmdC()

        // Poll for the copy to land — apps take tens of ms to service ⌘C.
        var captured: String?
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(50))
            if pasteboard.changeCount != clearedCount {
                captured = pasteboard.string(forType: .string)
                break
            }
        }

        if savedItems.isEmpty {
            // The clipboard was empty before the capture — "restore" means
            // clearing it, or the captured selection would linger there.
            pasteboard.clearContents()
        } else {
            restorePasteboard(pasteboard, items: savedItems)
        }
        log.debug("copySelection captured \(captured?.count ?? 0, privacy: .public) chars")

        // The pasteboard now holds the user's original clipboard again —
        // exactly what the fallback reads.
        return resolveCapture(
            selection: captured, clipboard: pasteboard.string(forType: .string)
        )
    }

    /// Selection wins when present; an empty capture falls back to the
    /// clipboard (#106). Whitespace-only counts as absent for both.
    /// Readability and the char limit are the caller's validation.
    nonisolated static func resolveCapture(
        selection: String?, clipboard: String?
    ) -> (text: String, fromClipboard: Bool)? {
        if let selection,
           !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (selection, false)
        }
        if let clipboard,
           !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (clipboard, true)
        }
        return nil
    }

    /// The current clipboard string — the unreadable-selection retry (#106)
    /// reads it after `copySelection` restored the original clipboard.
    @MainActor
    static func clipboardText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    // MARK: - Clipboard save/restore

    private struct PasteboardItem {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    /// The one place lore puts a string on the pasteboard, so the clipboard
    /// door (#192) has one place to learn the change count it must ignore.
    private static func writeString(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        PasteboardWriteLedger.shared.note(pasteboard.changeCount)
        pasteboard.setString(text, forType: .string)
        PasteboardWriteLedger.shared.note(pasteboard.changeCount)
    }

    private static func savePasteboard(_ pasteboard: NSPasteboard) -> [[PasteboardItem]] {
        var savedItems: [[PasteboardItem]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var typeData: [PasteboardItem] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeData.append(PasteboardItem(type: type, data: data))
                }
            }
            savedItems.append(typeData)
        }
        return savedItems
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard, items: [[PasteboardItem]]) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        PasteboardWriteLedger.shared.note(pasteboard.changeCount)
        for itemData in items {
            let item = NSPasteboardItem()
            for entry in itemData {
                item.setData(entry.data, forType: entry.type)
            }
            pasteboard.writeObjects([item])
            // The restore lands 800 ms after the paste — inside a following
            // dictation, if the user started one immediately (#192).
            PasteboardWriteLedger.shared.note(pasteboard.changeCount)
        }
    }
}
