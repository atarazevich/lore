import Foundation

/// The strings no diagnostic artifact may ever contain, shared by the three
/// suites that assert it (`DiagEventPrivacyTests`, `HealthSnapshotPrivacyTests`,
/// `ProblemReportTests`). One copy: the fixture set has to be edited whenever
/// the schema legitimately claims a word — "notes" did in #148 — and three
/// copies meant three edits and three chances to miss one.
enum PrivacyFixtures {

    static let transcript =
        "Remind me to email Sam about the Q3 revenue projections before Friday"
    static let deviceName = "Sam's AirPods Pro"
    /// The realistic secure-input leak: the panel shows the holder's name.
    static let secureInputHolder = "1Password"
    static let filePath = "~/Downloads/private_memo_final.m4a"
    static let apiKey = "sk-proj-abcdef1234567890"
    static let bundleID = "us.zoom.xos"

    /// Deliberately avoids words the schema legitimately owns — "Lore",
    /// "session", "dictation", "meetings", and "notes" since #148 named a probe
    /// and two events after the notes folder. A fixture must only match a
    /// *leak*, never a case name or an enum raw value.
    static let all = [transcript, deviceName, secureInputHolder, filePath, apiKey, bundleID]

    /// Individual words too — a leak of "AirPods" is a leak. Purely numeric
    /// tokens are dropped: they collide with timestamps and counts.
    static let tokens: [String] = all
        .flatMap { $0.split(whereSeparator: { " /_-".contains($0) }) }
        .map(String.init)
        .filter { $0.count >= 4 && $0.contains(where: \.isLetter) }

    /// Every string value in a decoded JSON tree. Keys are Swift-synthesized
    /// (case names, label names) and are not payload.
    static func stringValues(in object: Any) -> [String] {
        switch object {
        case let string as String:
            return [string]
        case let array as [Any]:
            return array.flatMap { stringValues(in: $0) }
        case let dictionary as [String: Any]:
            return dictionary.values.flatMap { stringValues(in: $0) }
        default:
            return []
        }
    }
}
