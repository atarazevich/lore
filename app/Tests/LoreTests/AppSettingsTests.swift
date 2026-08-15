import XCTest
@testable import LoreKit

@MainActor
final class AppSettingsTests: XCTestCase {

    private func makeSettings() -> AppSettings {
        isolatedSettings("AppSettingsTests")
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
