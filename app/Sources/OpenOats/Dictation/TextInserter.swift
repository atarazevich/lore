import AppKit
import os

enum TextInserter {
    private static let log = Logger(subsystem: "com.openoats", category: "TextInserter")

    /// Check if accessibility permission is granted (needed for CGEvent posting).
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the system to show the accessibility permission dialog.
    static func requestAccessibilityIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Paste text into the active application by:
    /// 1. Saving current clipboard
    /// 2. Setting clipboard to our text
    /// 3. Simulating Cmd+V
    /// 4. Restoring clipboard after a delay
    nonisolated(unsafe) private static var didRequestAccessibility = false

    static func paste(_ text: String) {
        guard isAccessibilityGranted else {
            if !didRequestAccessibility {
                log.warning("Accessibility not granted, requesting...")
                requestAccessibilityIfNeeded()
                didRequestAccessibility = true
            }
            return
        }

        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let savedItems = savePasteboard(pasteboard)

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        postCmdV()

        // Restore clipboard after delay
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            restorePasteboard(NSPasteboard.general, items: savedItems)
        }
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)

        // keyCode 9 = 'V'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            log.error("Failed to create CGEvent for Cmd+V")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
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
