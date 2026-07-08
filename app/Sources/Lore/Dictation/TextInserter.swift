import AppKit
import os

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
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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
    @discardableResult
    private static func postCmdZ() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        // keyCode 6 = 'Z'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: false) else {
            log.error("Failed to create CGEvent for Cmd+Z")
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Returns whether the synthetic key events could be *created*. Posting is
    /// fire-and-forget: `CGEvent.post` has no return value and no delivery receipt.
    @discardableResult
    private static func postCmdV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        // keyCode 9 = 'V'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            log.error("Failed to create CGEvent")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Use cghidEventTap — more reliable for posting synthetic events to other apps.
        // cgSessionEventTap is better for *reading* events; cghidEventTap injects at the
        // HID level which the frontmost app reliably receives.
        keyDown.post(tap: .cghidEventTap)
        usleep(20_000) // 20ms between key down and up for reliable delivery
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Clipboard save/restore

    private struct PasteboardItem {
        let type: NSPasteboard.PasteboardType
        let data: Data
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
        for itemData in items {
            let item = NSPasteboardItem()
            for entry in itemData {
                item.setData(entry.data, forType: entry.type)
            }
            pasteboard.writeObjects([item])
        }
    }
}
