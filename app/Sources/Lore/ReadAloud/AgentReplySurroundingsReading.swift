import AppKit
import CoreGraphics
import Foundation

/// Reads `AgentReplySurroundings` (#354) and hands the reading back on the main
/// actor. The live reader answers later, off a queue of its own; a test's
/// answers at once. Either way the controller files and continues in the
/// callback, so there is one path.
@MainActor
protocol AgentReplySurroundingsReading: AnyObject {
    func read(_ done: @escaping @MainActor (AgentReplySurroundings) -> Void)
}

/// The live reading, taken when a reply arrives, when one finishes, and when
/// the capsule's tooltip is shown — never stored as a verdict.
@MainActor
final class LiveAgentReplySurroundings: AgentReplySurroundingsReading {
    /// The HAL, the window list and bundles are read here, never on the main
    /// thread (#64).
    private static let queue = DispatchQueue(label: "com.lore.replies.surroundings", qos: .userInitiated)

    func read(_ done: @escaping @MainActor (AgentReplySurroundings) -> Void) {
        // The frontmost app's identity is the one main-thread read: two
        // properties of an object AppKit keeps current.
        let front = NSWorkspace.shared.frontmostApplication
            .flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
            .map { (pid: $0.processIdentifier, bundle: $0.bundleURL) }
        Self.queue.async {
            let reading = AgentReplySurroundings(
                gameInFront: front.map { Self.isGame(pid: $0.pid, bundle: $0.bundle) } ?? false,
                otherAppSound: CoreAudioSignalSource.anotherProcessRunsOutput()
            )
            Task { @MainActor in done(reading) }
        }
    }

    private nonisolated static func isGame(pid: pid_t, bundle: URL?) -> Bool {
        let category = bundle.flatMap(Bundle.init(url:))?
            .object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        return AgentReplyGame.isGame(category: category, capturesDisplay: capturesDisplay(pid: pid))
    }

    /// A window of `pid` at the shielding level as large as a screen — what a
    /// game that captured the display draws. Layer, owner and bounds need no
    /// Screen Recording grant; only window names do, and none is read.
    private nonisolated static func capturesDisplay(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let shielding = Int(CGShieldingWindowLevel())
        let displays = activeDisplaySizes()
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, layer >= shielding,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return false }
            return displays.contains(rect.size)
        }
    }

    /// The displays' sizes in points, from CoreGraphics rather than `NSScreen`,
    /// which belongs to the main thread.
    private nonisolated static func activeDisplaySizes() -> [CGSize] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.map { CGDisplayBounds($0).size }
    }
}
