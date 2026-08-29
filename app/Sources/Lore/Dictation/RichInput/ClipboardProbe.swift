import AppKit
import os

/// Step 0 of #192, and nothing else: macOS 26.4 shipped an alert on
/// programmatic pasteboard reads, and which of the three reads the clipboard
/// door makes actually alerts on this machine cannot be read from code — only a
/// human watching the screen can answer it.
///
/// The probe reads the pasteboard three ways, a second and a half apart so an
/// alert can be attributed to one read, and records each with its result. Fired
/// by Fn+P (`HotkeyManager`), which exists for this and is removable with this
/// file.
enum ClipboardProbe {
    private static let log = Logger(subsystem: "com.lore.app", category: "ClipboardProbe")

    /// Widest to narrowest: `changeCount` alone (what the poll costs every
    /// 100 ms), then the type list, then the bytes of the first type.
    @MainActor
    static func run(pasteboard: NSPasteboard = .general) async {
        let changeCount = pasteboard.changeCount
        DiagStore.record(.clipboardProbeRead(read: .changeCount, result: changeCount))
        log.info("probe: changeCount = \(changeCount, privacy: .public)")

        try? await Task.sleep(for: .milliseconds(1500))
        let types = pasteboard.types ?? []
        DiagStore.record(.clipboardProbeRead(read: .types, result: types.count))
        log.info("probe: types = \(types.count, privacy: .public)")

        try? await Task.sleep(for: .milliseconds(1500))
        let bytes = types.first.flatMap { pasteboard.data(forType: $0)?.count } ?? 0
        DiagStore.record(.clipboardProbeRead(read: .data, result: bytes))
        log.info("probe: data bytes = \(bytes, privacy: .public)")
    }
}
