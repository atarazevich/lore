import AppKit
import os

enum TextInserter {
    private static let log = Logger(subsystem: "com.openoats", category: "TextInserter")

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    nonisolated(unsafe) private static var didRequestAccessibility = false

    static func paste(_ text: String) {
        diagLog("[PASTE] paste called, accessibility=\(isAccessibilityGranted)")

        guard isAccessibilityGranted else {
            if !didRequestAccessibility {
                log.warning("Accessibility not granted, requesting...")
                requestAccessibilityIfNeeded()
                didRequestAccessibility = true
            }
            diagLog("[PASTE] accessibility not granted, skipping paste")
            return
        }

        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let savedItems = savePasteboard(pasteboard)

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        diagLog("[PASTE] clipboard set, posting Cmd+V")

        // Small delay to let clipboard settle, then simulate Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            postCmdV()
            diagLog("[PASTE] Cmd+V posted")

            // Restore clipboard after target app processes the paste
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                restorePasteboard(NSPasteboard.general, items: savedItems)
                diagLog("[PASTE] clipboard restored")
            }
        }
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)

        // keyCode 9 = 'V'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            log.error("Failed to create CGEvent")
            diagLog("[PASTE] ERROR: failed to create CGEvent")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Try cgSessionEventTap (works for more apps than cghidEventTap)
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
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
