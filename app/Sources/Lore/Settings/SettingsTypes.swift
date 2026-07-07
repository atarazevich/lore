import AppKit
import Foundation

enum HotkeyKey: String, CaseIterable, Identifiable, Codable {
    case fn
    case rightOption

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: "Fn (Globe)"
        case .rightOption: "Right Option (\u{2325})"
        }
    }

    /// Check if this key matches the given flags-changed event.
    func matchesPress(_ event: NSEvent) -> Bool {
        switch self {
        case .fn:
            return event.modifierFlags.contains(.function)
        case .rightOption:
            return event.modifierFlags.contains(.option) && event.keyCode == 61
        }
    }
}
