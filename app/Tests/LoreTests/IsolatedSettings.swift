import Foundation
@testable import LoreKit

/// Settings backed by storage nothing else can see: a fresh UserDefaults suite
/// and an ephemeral secret store. Tests must never build `AppSettings()` — its
/// default storage is `.live()`, i.e. the user's real Keychain and defaults.
///
/// `defaults` is passed in when the caller needs to seed or read the same suite
/// (the meeting harness seeds the notes folder and the #150 setup flag).
@MainActor
func isolatedSettings(
    _ label: String,
    defaults: UserDefaults? = nil,
    notesDirectory: URL? = nil,
    apiKey: String? = nil
) -> AppSettings {
    let suite: UserDefaults
    if let defaults {
        suite = defaults
    } else {
        let suiteName = "\(label)-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
    }
    let settings = AppSettings(storage: AppSettingsStorage(
        defaults: suite,
        secretStore: .ephemeral,
        defaultNotesDirectory: notesDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(label),
        legacyNotesDirectories: [],
        runMigrations: false
    ))
    if let apiKey { settings.openaiApiKey = apiKey }
    return settings
}
