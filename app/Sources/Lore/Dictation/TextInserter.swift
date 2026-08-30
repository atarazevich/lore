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

    @MainActor
    @discardableResult
    static func paste(_ text: String) async -> Bool {
        await paste([.text(text)])
    }

    /// A dictation's delivery, in order (#195). One step for a terminal; for a
    /// web composer, the words up to a picture, then the picture as a file on
    /// the pasteboard, then the words after it — a composer cannot be handed a
    /// picture inside a string.
    ///
    /// Each step writes the pasteboard and posts its own Cmd+V; the user's
    /// clipboard is saved once before the first step and restored once after
    /// the last, because restoring between steps would hand the target its own
    /// old clipboard mid-sequence.
    ///
    /// Answers whether every step's keystrokes could be **created** (#209) —
    /// the only fact this path has, and the whole of what the bubble's
    /// paste-failed face is allowed to claim. Whoever wants that answer waits
    /// for it; whoever does not, does not, which is how the bubble leaves at the
    /// first step while a web composer is still being handed its third.
    @MainActor
    @discardableResult
    static func paste(_ steps: [RichInput.DeliveryStep]) async -> Bool {
        // Nothing was asked for, so nothing failed.
        guard !steps.isEmpty else { return true }
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

        var allPosted = true
        for (index, step) in steps.enumerated() {
            switch step {
            case .text(let text): writeString(text, to: pasteboard)
            case .files(let paths): writeFileURLs(paths, to: pasteboard)
            }

            // Small delay to let clipboard settle, then simulate Cmd+V.
            try? await Task.sleep(for: .milliseconds(50))

            // `postCmdV` reports only whether the CGEvents could be *created*.
            // `CGEvent.post` returns nothing, so whether the paste reached an app is
            // unobservable from here — an `Outcome.ok` would have read "fine" in
            // precisely the incident this feature exists to diagnose. One event per
            // step, so a sequence that stopped halfway says where.
            let eventsCreated = postCmdV()
            DiagStore.record(.pasteAttempt(
                kind: .paste,
                eventsCreated: eventsCreated,
                accessibilityTrusted: granted
            ))
            // Nothing was posted, so nothing later will land in the right
            // place either: stop, restore, and leave the words that did
            // arrive where they are.
            guard eventsCreated else {
                allPosted = false
                break
            }
            guard index < steps.count - 1 else { break }
            try? await Task.sleep(for: settle(after: step))
        }

        // The clipboard goes back behind the answer, not in front of it: the
        // 800 ms the target needs to absorb the last paste is not the caller's
        // wait, and the caller's question was answered a line ago.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            restorePasteboard(NSPasteboard.general, items: savedItems)
            log.debug("clipboard restored")
        }
        return allPosted
    }

    /// How long the target needs before the next step. A composer attaches a
    /// file asynchronously — it uploads a thumbnail, moves the caret, rebuilds
    /// the box — and a paste arriving mid-attachment is the one that gets
    /// dropped. Words are absorbed as fast as they are typed.
    private static func settle(after step: RichInput.DeliveryStep) -> Duration {
        switch step {
        case .text: .milliseconds(250)
        case .files: .milliseconds(600)
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
    private static func postCmdV() -> Bool { postCommandChord(0x09) } // 9 = 'V'

    @discardableResult
    private static func postCmdC() -> Bool { postCommandChord(0x08) } // 8 = 'C'

    /// Press the system's "copy selected area to clipboard" shortcut for the
    /// user (#192): the familiar crosshair appears, the drag lands a PNG on the
    /// clipboard with no file and no thumbnail delay, and the clipboard door
    /// picks it up at the second it happened.
    ///
    /// `fullScreen` posts the whole-screen variant (Ctrl+Shift+Cmd+3) instead
    /// of the crosshair — what the redirect of a system Cmd+Shift+3 needs so
    /// the user gets the shot they asked for (#199).
    @discardableResult
    static func postScreenshotToClipboard(fullScreen: Bool = false) -> Bool {
        // 21 = '4' (drag a region), 20 = '3' (the whole screen).
        let created = postCommandChord(
            fullScreen ? 0x14 : 0x15, flags: [.maskCommand, .maskShift, .maskControl]
        )
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

    /// One pasteboard carrying one item per file, each a `public.file-url`
    /// (#195). Chrome and WebKit walk every such item and attach every file
    /// under its real name, where a paste carrying image *bytes* exposes only
    /// the first picture — `dataForType:` reads the first item that has the
    /// type and stops.
    ///
    /// Goes through the write ledger like every other lore write, so the
    /// clipboard door does not read the app's own attachment back as material
    /// for the next dictation.
    private static func writeFileURLs(_ paths: [String], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        PasteboardWriteLedger.shared.note(pasteboard.changeCount)
        pasteboard.writeObjects(paths.map { path in
            let item = NSPasteboardItem()
            item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
            return item
        })
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
