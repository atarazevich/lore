import XCTest
@testable import LoreKit

@MainActor
final class AppSettingsTests: XCTestCase {

    /// Isolated settings: ephemeral suite + ephemeral secret store. Tests
    /// must never construct `AppSettings()` — the default storage is
    /// `.live()`, which reads the user's real Keychain and UserDefaults.
    private func makeSettings() -> AppSettings {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let storage = AppSettingsStorage(
            defaults: suite,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("AppSettingsTests"),
            runMigrations: false
        )
        return AppSettings(storage: storage)
    }

    // MARK: - AppSettings Defaults

    func testAppSettingsDefaultTranscriptionLocale() {
        let settings = makeSettings()
        // Default locale should be en-US unless previously set
        XCTAssertFalse(settings.transcriptionLocale.isEmpty)
    }

    func testAppSettingsLocaleProperty() {
        let settings = makeSettings()
        let locale = settings.locale
        XCTAssertFalse(locale.identifier.isEmpty)
    }

}
