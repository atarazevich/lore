import XCTest
@testable import LoreKit

@MainActor
final class SettingsStoreTests: XCTestCase {

    /// Fresh ephemeral suite — UUID name, so nothing is persisted to clear.
    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "com.lore.test.\(UUID().uuidString)")!
    }

    /// Suite with hideFromScreenShare pre-seeded (setter avoided: it touches NSApp.windows).
    private func makeSuite(hideFromScreenShare: Bool) -> UserDefaults {
        let suite = makeSuite()
        suite.set(hideFromScreenShare, forKey: "hideFromScreenShare")
        return suite
    }

    /// Build a SettingsStore backed by an ephemeral UserDefaults suite.
    private func makeStore(
        defaults: UserDefaults? = nil,
        secretStore: AppSecretStore = .ephemeral
    ) -> SettingsStore {
        let suite = defaults ?? makeSuite()

        let storage = SettingsStorage(
            defaults: suite,
            secretStore: secretStore,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SettingsStoreTests"),
            runMigrations: false
        )
        return SettingsStore(storage: storage)
    }

    // MARK: - AI Settings Group

    func testDefaultEnableTranscriptRefinement() {
        let store = makeStore()
        XCTAssertFalse(store.enableTranscriptRefinement)
    }

    func testEnableTranscriptRefinementRoundTrip() {
        let store = makeStore()
        store.enableTranscriptRefinement = true
        XCTAssertTrue(store.enableTranscriptRefinement)
    }

    // MARK: - Capture Settings Group

    func testDefaultInputDeviceID() {
        let store = makeStore()
        XCTAssertEqual(store.inputDeviceID, 0)
    }

    func testDefaultTranscriptionLocale() {
        let store = makeStore()
        XCTAssertEqual(store.transcriptionLocale, "en-US")
    }

    func testDefaultSaveAudioRecording() {
        let store = makeStore()
        XCTAssertFalse(store.saveAudioRecording)
    }

    func testDefaultEnableBatchRefinement() {
        let store = makeStore()
        // Defaults to true when key never set (#109): every stopped meeting
        // rebuilds its transcript from the whole audio. An explicit prior
        // choice (true or false) still persists and is honored.
        XCTAssertTrue(store.enableBatchRefinement)
    }

    // MARK: - Detection Settings Group

    func testDefaultMeetingAutoDetect() {
        let store = makeStore()
        // Defaults to true when key never set (#91): auto-capture is on out of
        // the box so the app is useful on a fresh install. An explicit prior
        // choice still persists (see testMeetingAutoDetectRoundTrip).
        XCTAssertTrue(store.meetingAutoDetectEnabled)
    }

    /// An explicit `false` must survive a fresh launch (#91): flipping the unset
    /// default to `true` must not clobber a user who turned auto-capture off.
    /// Two stores over one suite exercise the init `else` (from-persisted) branch,
    /// which a same-instance round-trip would never reach.
    func testMeetingAutoDetectExplicitFalseSurvivesRelaunch() {
        let suite = makeSuite()
        makeStore(defaults: suite).meetingAutoDetectEnabled = false
        // Second store reads the persisted key, not the true default.
        XCTAssertFalse(makeStore(defaults: suite).meetingAutoDetectEnabled)
    }

    /// Mirror: an unset key yields the new `true` default on a fresh store.
    func testMeetingAutoDetectDefaultsTrueWhenUnset() {
        XCTAssertTrue(makeStore(defaults: makeSuite()).meetingAutoDetectEnabled)
    }

    func testDefaultSilenceTimeoutMinutes() {
        let store = makeStore()
        XCTAssertEqual(store.silenceTimeoutMinutes, 15)
    }

    func testSilenceTimeoutMinutesRoundTrip() {
        let store = makeStore()
        store.silenceTimeoutMinutes = 30
        XCTAssertEqual(store.silenceTimeoutMinutes, 30)
    }

    func testDefaultCustomMeetingAppBundleIDs() {
        let store = makeStore()
        XCTAssertEqual(store.customMeetingAppBundleIDs, [])
    }

    func testCustomMeetingAppBundleIDsRoundTrip() {
        let store = makeStore()
        store.customMeetingAppBundleIDs = ["com.example.app"]
        XCTAssertEqual(store.customMeetingAppBundleIDs, ["com.example.app"])
    }

    // MARK: - Privacy Settings Group

    func testDefaultHasAcknowledgedRecordingConsent() {
        let store = makeStore()
        XCTAssertFalse(store.hasAcknowledgedRecordingConsent)
    }

    func testHasAcknowledgedRecordingConsentRoundTrip() {
        let store = makeStore()
        store.hasAcknowledgedRecordingConsent = true
        XCTAssertTrue(store.hasAcknowledgedRecordingConsent)
    }

    func testDefaultHideFromScreenShare() {
        let store = makeStore()
        // Defaults to true when key never set
        XCTAssertTrue(store.hideFromScreenShare)
    }

    func testScreenSharingTypeWhenKeyAbsent() {
        let store = makeStore()
        // Absent key = privacy default: hidden from capture
        XCTAssertEqual(store.screenSharingType, .none)
    }

    func testScreenSharingTypeWhenHidingEnabled() {
        let store = makeStore(defaults: makeSuite(hideFromScreenShare: true))
        XCTAssertEqual(store.screenSharingType, .none)
    }

    func testScreenSharingTypeWhenHidingDisabled() {
        let store = makeStore(defaults: makeSuite(hideFromScreenShare: false))
        XCTAssertEqual(store.screenSharingType, .readOnly)
    }

    func testScreenSharingTypeFromRawDefaults() {
        // Panels read this static directly; same on/off/absent contract.
        XCTAssertEqual(SettingsStore.screenSharingType(from: makeSuite()), .none)
        XCTAssertEqual(SettingsStore.screenSharingType(from: makeSuite(hideFromScreenShare: true)), .none)
        XCTAssertEqual(SettingsStore.screenSharingType(from: makeSuite(hideFromScreenShare: false)), .readOnly)
    }

    // MARK: - UI Settings Group

    func testDefaultShowLiveTranscript() {
        let store = makeStore()
        // Defaults to true when key never set
        XCTAssertTrue(store.showLiveTranscript)
    }

    func testShowLiveTranscriptRoundTrip() {
        let store = makeStore()
        store.showLiveTranscript = false
        XCTAssertFalse(store.showLiveTranscript)
    }

    func testLocaleProperty() {
        let store = makeStore()
        XCTAssertEqual(store.locale.identifier, "en-US")
    }

    // MARK: - Persistence via UserDefaults

    func testPersistenceAcrossInstances() {
        let suiteName = "com.lore.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store1 = makeStore(defaults: defaults)
        store1.transcriptionLocale = "ru-RU"
        store1.silenceTimeoutMinutes = 42

        // Create a second store from the same defaults
        let store2 = makeStore(defaults: defaults)
        XCTAssertEqual(store2.transcriptionLocale, "ru-RU")
        XCTAssertEqual(store2.silenceTimeoutMinutes, 42)
    }

    // MARK: - XMO Settings destination keys (Stage D, additive)

    func testDefaultRecPillEnabled() {
        let store = makeStore()
        XCTAssertTrue(store.recPillEnabled)
    }

    func testRecPillEnabledRoundTrip() {
        let store = makeStore()
        store.recPillEnabled = false
        XCTAssertFalse(store.recPillEnabled)
    }

    func testDefaultSoundOnDictationStart() {
        let store = makeStore()
        XCTAssertFalse(store.soundOnDictationStart)
    }

    func testSoundOnDictationStartRoundTrip() {
        let store = makeStore()
        store.soundOnDictationStart = true
        XCTAssertTrue(store.soundOnDictationStart)
    }

    func testModifierTogglesDefaultOn() {
        let store = makeStore()
        XCTAssertTrue(store.modifierLockEnabled)
        XCTAssertTrue(store.modifierCleanupEnabled)
        XCTAssertTrue(store.modifierTranslateEnabled)
        XCTAssertTrue(store.modifierUpgradeKeysEnabled)
    }

    /// #52: absent key must map to 500 — the pre-setting hardcoded policy —
    /// so existing installs see no behavior change.
    func testDefaultDictationAudioRetention() {
        let store = makeStore()
        XCTAssertEqual(store.dictationAudioRetentionCount, 500)
    }

    func testDictationAudioRetentionPersistsAcrossInstances() {
        let suiteName = "com.lore.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store1 = makeStore(defaults: defaults)
        store1.dictationAudioRetentionCount = 100
        XCTAssertEqual(makeStore(defaults: defaults).dictationAudioRetentionCount, 100)

        // 0 = unlimited sentinel round-trips (must not fall back to 500).
        store1.dictationAudioRetentionCount = 0
        XCTAssertEqual(makeStore(defaults: defaults).dictationAudioRetentionCount, 0)
    }

    func testModifierTogglesPersistAcrossInstances() {
        let suiteName = "com.lore.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store1 = makeStore(defaults: defaults)
        store1.modifierLockEnabled = false
        store1.modifierUpgradeKeysEnabled = false

        let store2 = makeStore(defaults: defaults)
        XCTAssertFalse(store2.modifierLockEnabled)
        XCTAssertTrue(store2.modifierCleanupEnabled)
        XCTAssertTrue(store2.modifierTranslateEnabled)
        XCTAssertFalse(store2.modifierUpgradeKeysEnabled)
    }

    // MARK: - AppSettings Typealias Compatibility

    func testTypealiasCompiles() {
        // Verify that AppSettings typealias resolves to SettingsStore
        let _: AppSettings.Type = SettingsStore.self
    }

    // MARK: - AppSettingsStorage Typealias Compatibility

    func testStorageTypealiasCompiles() {
        let _: AppSettingsStorage.Type = SettingsStorage.self
    }
}
