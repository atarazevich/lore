import XCTest
@testable import LoreKit

/// The method/language meta on a history entry must reflect only cleanups
/// that actually happened: when the LLM call cannot run (here: no settings /
/// no API key, the same failure path as a network error — `cleanupEntry`
/// returns false), no meta is written and the entry text stays untouched.
@MainActor
final class DictationCoordinatorMetaGatingTests: XCTestCase {

    /// LLM client that always fails — the same observable outcome as a
    /// revoked key's HTTP 401 (#50).
    private struct FailingCleanupClient: CleanupProviding {
        func cleanup(rawText: String, prompt: String, apiKey: String) async throws -> String {
            throw CleanupClient.CleanupError.apiError(401)
        }
    }

    /// Coordinator backed by an ephemeral UserDefaults suite and temp
    /// directories so the user's real dictation history is never touched.
    private func makeCoordinator(
        cleanupClient: any CleanupProviding = CleanupClient()
    ) -> DictationCoordinator {
        let name = "com.lore.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MetaGatingTests-\(UUID().uuidString)", isDirectory: true)
        return DictationCoordinator(
            history: DictationHistory(
                defaults: defaults,
                entriesDirectory: tmp.appendingPathComponent("entries"),
                audioDirectory: tmp.appendingPathComponent("audio")
            ),
            cleanupClient: cleanupClient
        )
    }

    /// Settings with a (fake) API key, backed by ephemeral storage — no
    /// Keychain, no real defaults.
    private func makeSettings(apiKey: String) -> AppSettings {
        let name = "com.lore.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let storage = SettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DictationCoordinatorMetaGatingTests"),
            runMigrations: false
        )
        let settings = SettingsStore(storage: storage)
        settings.openaiApiKey = apiKey
        return settings
    }

    private func addTranscribedEntry(to coordinator: DictationCoordinator) -> DictationHistoryEntry {
        var entry = DictationHistoryEntry(durationSeconds: 3.0)
        entry.status = .transcribed
        entry.rawText = "hello world"
        coordinator.history.add(entry)
        return entry
    }

    func testFailedRetroactiveCleanupWritesNoMethodMeta() async {
        let coordinator = makeCoordinator()
        let entry = addTranscribedEntry(to: coordinator)

        await coordinator.cleanupHistoryEntry(entryID: entry.id, method: .bulletPoints)

        let updated = coordinator.history.entries.first { $0.id == entry.id }!
        XCTAssertNil(updated.cleanupMethodName)
        XCTAssertNil(updated.translatedToLanguage)
        XCTAssertNil(updated.cleanedText)
        XCTAssertEqual(updated.status, .transcribed)
    }

    func testFailedRetroactiveTranslateWritesNoLanguageMeta() async {
        let coordinator = makeCoordinator()
        let entry = addTranscribedEntry(to: coordinator)

        await coordinator.translateHistoryEntry(entryID: entry.id, to: .german)

        let updated = coordinator.history.entries.first { $0.id == entry.id }!
        XCTAssertNil(updated.translatedToLanguage)
        XCTAssertNil(updated.cleanupMethodName)
        XCTAssertNil(updated.cleanedText)
        XCTAssertEqual(updated.status, .transcribed)
    }

    /// A failed transform must not clobber the meta of a previous successful
    /// one: the old cleaned text stays displayed, so its label must survive.
    func testFailedTransformKeepsPreviousMeta() async {
        let coordinator = makeCoordinator()
        var entry = addTranscribedEntry(to: coordinator)
        entry.status = .cleaned
        entry.cleanedText = "Hello world."
        entry.activeVersion = .cleaned
        entry.cleanupMethodName = CleanupMethod.formalTone.key
        coordinator.history.update(entry)

        await coordinator.translateHistoryEntry(entryID: entry.id, to: .french)

        let updated = coordinator.history.entries.first { $0.id == entry.id }!
        XCTAssertEqual(updated.cleanupMethodName, CleanupMethod.formalTone.key)
        XCTAssertNil(updated.translatedToLanguage)
        XCTAssertEqual(updated.cleanedText, "Hello world.")
    }

    // MARK: - Failure surfacing (#50)

    /// A paste-time cleanup failure (revoked key → API error) must surface a
    /// user-facing error the floating indicator renders — never a silent
    /// raw-text paste that looks like success.
    func testPasteTimeCleanupFailureSetsUserFacingError() async {
        let coordinator = makeCoordinator(cleanupClient: FailingCleanupClient())
        coordinator.settings = makeSettings(apiKey: "sk-revoked")
        var entry = addTranscribedEntry(to: coordinator)

        let ok = await coordinator.cleanupEntry(
            &entry, rawText: "hello world", prompt: "clean it up",
            failureMessage: DictationCoordinator.cleanupFailedPastedRaw
        )

        XCTAssertFalse(ok)
        XCTAssertEqual(coordinator.lastError, DictationCoordinator.cleanupFailedPastedRaw)
        // Raw-paste fallback data unchanged: no cleaned text, no relabeling.
        XCTAssertNil(entry.cleanedText)
        XCTAssertEqual(entry.status, .transcribed)
    }

    /// Without a failure message (row-transform path) a failed call must NOT
    /// touch `lastError` — the history row owns that feedback, not the
    /// floating indicator.
    func testRowTransformFailureReturnsFalseWithoutIndicatorError() async {
        let coordinator = makeCoordinator(cleanupClient: FailingCleanupClient())
        coordinator.settings = makeSettings(apiKey: "sk-revoked")
        let entry = addTranscribedEntry(to: coordinator)

        let ok = await coordinator.cleanupHistoryEntry(entryID: entry.id, method: .standard)

        XCTAssertFalse(ok)
        XCTAssertNil(coordinator.lastError)
    }
}
