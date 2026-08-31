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
            legacyNotesDirectories: [],
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

    // MARK: - Meetings Master Switch (#221)

    /// Nothing in the domain means nobody has ever run lore here: Meetings is
    /// off, and the verdict is written down rather than left to be re-derived.
    func testMeetingsOffOnAFreshInstall() {
        let suite = makeSuite()
        XCTAssertFalse(makeStore(defaults: suite).meetingsEnabled)
        XCTAssertEqual(suite.object(forKey: "meetingsEnabled") as? Bool, false)
    }

    /// Any one of the keys an earlier launch leaves behind is enough: a Mac
    /// that has used lore keeps Meetings exactly where it was.
    func testMeetingsOnWhenTheMacHasRunLoreBefore() {
        for key in NotesFolderMigration.priorLaunchKeys {
            let suite = makeSuite()
            suite.set(true, forKey: key)
            XCTAssertTrue(makeStore(defaults: suite).meetingsEnabled,
                          "\(key) is prior-install evidence")
        }
    }

    /// The evidence is presence, not truth — #148 reads these keys the same
    /// way, and a stored `false` is still a key an earlier launch wrote.
    func testMeetingsOnWhenPriorEvidenceIsPresentButFalse() {
        let suite = makeSuite()
        suite.set(false, forKey: "didMigrateFromOnTheSpot")
        XCTAssertTrue(makeStore(defaults: suite).meetingsEnabled)
    }

    /// An explicit choice wins in both directions, evidence or not.
    func testStoredMeetingsChoiceAlwaysWins() {
        let onSuite = makeSuite()
        onSuite.set(true, forKey: "meetingsEnabled")
        XCTAssertTrue(makeStore(defaults: onSuite).meetingsEnabled)

        let offSuite = makeSuite()
        offSuite.set(true, forKey: "didMigrateFromOpenGranola")
        offSuite.set(false, forKey: "meetingsEnabled")
        XCTAssertFalse(makeStore(defaults: offSuite).meetingsEnabled)
    }

    /// Why the verdict is stamped rather than re-derived: the first launch
    /// itself writes the evidence keys, so a second launch reading them fresh
    /// would turn Meetings on behind the user's back.
    func testFreshInstallStaysOffOnceItsOwnFirstLaunchKeysExist() {
        let suite = makeSuite()
        XCTAssertFalse(makeStore(defaults: suite).meetingsEnabled)

        // What launch one leaves behind (the bundle migrations always run).
        suite.set(true, forKey: "didMigrateFromOnTheSpot")
        suite.set(true, forKey: "didMigrateFromOpenGranola")

        XCTAssertFalse(makeStore(defaults: suite).meetingsEnabled)
    }

    /// And the switch itself is not evidence — otherwise stamping it would
    /// make every fresh install look like a prior one to #148's notes move.
    func testTheSwitchIsNotPriorInstallEvidence() {
        let suite = makeSuite()
        _ = makeStore(defaults: suite)
        XCTAssertFalse(NotesFolderMigration.hasPriorInstall(defaults: suite))
    }

    func testMeetingsEnabledRoundTrip() {
        let suite = makeSuite()
        makeStore(defaults: suite).meetingsEnabled = true
        XCTAssertTrue(makeStore(defaults: suite).meetingsEnabled)
    }

    // MARK: - Send to the operator (#223)

    /// The same rule as Meetings, on the same evidence: nothing in the domain
    /// is a fresh install, and Fn+K starts off with the verdict written down.
    func testOperatorSendOffOnAFreshInstall() {
        let suite = makeSuite()
        XCTAssertFalse(makeStore(defaults: suite).operatorSendEnabled)
        XCTAssertEqual(suite.object(forKey: "operatorSendEnabled") as? Bool, false)
    }

    /// A Mac that has run lore before keeps Fn+K exactly where it was —
    /// any one of the evidence keys is enough.
    func testOperatorSendOnWhenTheMacHasRunLoreBefore() {
        for key in NotesFolderMigration.priorLaunchKeys {
            let suite = makeSuite()
            suite.set(true, forKey: key)
            XCTAssertTrue(makeStore(defaults: suite).operatorSendEnabled,
                          "\(key) is prior-install evidence")
        }
    }

    /// An explicit choice wins in both directions, evidence or not.
    func testStoredOperatorSendChoiceAlwaysWins() {
        let onSuite = makeSuite()
        onSuite.set(true, forKey: "operatorSendEnabled")
        XCTAssertTrue(makeStore(defaults: onSuite).operatorSendEnabled)

        let offSuite = makeSuite()
        offSuite.set(true, forKey: "didMigrateFromOpenGranola")
        offSuite.set(false, forKey: "operatorSendEnabled")
        XCTAssertFalse(makeStore(defaults: offSuite).operatorSendEnabled)
    }

    /// Why the verdict is stamped rather than re-derived: the first launch
    /// writes the evidence keys itself, so a second launch reading them fresh
    /// would turn Fn+K on behind the user's back.
    func testFreshInstallKeepsTheOperatorSwitchOffOnItsSecondLaunch() {
        let suite = makeSuite()
        XCTAssertFalse(makeStore(defaults: suite).operatorSendEnabled)

        suite.set(true, forKey: "didMigrateFromOnTheSpot")
        suite.set(true, forKey: "didMigrateFromOpenGranola")

        XCTAssertFalse(makeStore(defaults: suite).operatorSendEnabled)
    }

    /// Neither switch is evidence — not for #148's notes move, and not for each
    /// other: stamping one must not make the next one read a prior install.
    func testNeitherMasterSwitchIsPriorInstallEvidence() {
        let suite = makeSuite()
        let store = makeStore(defaults: suite)
        XCTAssertFalse(store.meetingsEnabled)
        XCTAssertFalse(store.operatorSendEnabled)
        XCTAssertFalse(NotesFolderMigration.hasPriorInstall(defaults: suite))
    }

    /// The upgrade path. Until #223 the chord was gated by the MODIFIERS "Extra
    /// keys" toggle, so a stored `false` there is a user who already said no to
    /// Fn+K: that choice carries over ahead of the prior-install evidence that
    /// would otherwise turn the new switch on, and is stamped under the new key.
    func testAStoredExtraKeysOffCarriesOverIntoTheOperatorSwitch() {
        let suite = makeSuite()
        suite.set(true, forKey: "didMigrateFromOnTheSpot") // evidence alone would say on
        suite.set(false, forKey: "modifierUpgradeKeysEnabled")

        XCTAssertFalse(makeStore(defaults: suite).operatorSendEnabled)
        XCTAssertEqual(suite.object(forKey: "operatorSendEnabled") as? Bool, false,
                       "the verdict is stamped, so the retired key is read once")
    }

    /// The retired toggle on — its default, and it also meant Fn+S — says
    /// nothing about Fn+K in particular, and neither does its absence. Both fall
    /// to the evidence rule, in both directions.
    func testExtraKeysOnOrAbsentLeavesTheEvidenceRuleAlone() {
        for retired in [true, nil] as [Bool?] {
            let named = retired.map(String.init(describing:)) ?? "absent"

            let priorInstall = makeSuite()
            priorInstall.set(true, forKey: "didMigrateFromOnTheSpot")
            if let retired { priorInstall.set(retired, forKey: "modifierUpgradeKeysEnabled") }
            XCTAssertTrue(makeStore(defaults: priorInstall).operatorSendEnabled,
                          "prior install, retired key \(named)")

            let fresh = makeSuite()
            if let retired { fresh.set(retired, forKey: "modifierUpgradeKeysEnabled") }
            XCTAssertFalse(makeStore(defaults: fresh).operatorSendEnabled,
                           "fresh install, retired key \(named)")
        }
    }

    /// And an explicit choice under the new key outranks the migration.
    func testAStoredOperatorChoiceOutranksTheRetiredToggle() {
        let suite = makeSuite()
        suite.set(false, forKey: "modifierUpgradeKeysEnabled")
        suite.set(true, forKey: "operatorSendEnabled")

        XCTAssertTrue(makeStore(defaults: suite).operatorSendEnabled)
    }

    func testOperatorSendEnabledRoundTrip() {
        let suite = makeSuite()
        makeStore(defaults: suite).operatorSendEnabled = true
        XCTAssertTrue(makeStore(defaults: suite).operatorSendEnabled)
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

    // MARK: - Setup gate (#150)

    /// A store built on an empty domain is a fresh install: setup incomplete.
    func testDefaultDidCompleteSetup() {
        let store = makeStore()
        XCTAssertFalse(store.didCompleteSetup)
    }

    func testMarkSetupCompletedPersists() {
        let suite = makeSuite()
        let store = makeStore(defaults: suite)
        store.markSetupCompleted()
        XCTAssertTrue(store.didCompleteSetup)
        XCTAssertTrue(suite.bool(forKey: SetupState.completedKey))
    }

    // MARK: - Privacy Settings Group

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

    // MARK: - Lore Settings destination keys (Stage D, additive)

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
        store1.modifierTranslateEnabled = false

        let store2 = makeStore(defaults: defaults)
        XCTAssertFalse(store2.modifierLockEnabled)
        XCTAssertTrue(store2.modifierCleanupEnabled)
        XCTAssertFalse(store2.modifierTranslateEnabled)
    }

    // MARK: - Notes folder (#148)

    /// The launch-path invariant, pinned where it broke: constructing the
    /// settings must not create — or otherwise touch — the notes folder.
    /// Before #148 this `init` ran `createDirectory` on `notesFolderPath`, and
    /// since that path defaulted into `~/Documents`, launching the app raised a
    /// Documents-access dialog on a fresh install. The folder is created at
    /// first use instead (`NotesFolder.prepare`).
    func testInitDoesNotCreateOrTouchTheNotesFolder() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SettingsStoreNotes-\(UUID().uuidString)", isDirectory: true)
        let storage = SettingsStorage(
            defaults: makeSuite(),
            secretStore: .ephemeral,
            defaultNotesDirectory: folder,
            legacyNotesDirectories: [],
            runMigrations: false
        )

        let store = SettingsStore(storage: storage)

        XCTAssertEqual(store.notesFolderPath, folder.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path),
                       "launching must not create the notes folder — first use does")
    }

    /// One legacy-folder upgrade wired the way the app wires it: temp folders
    /// injected as the legacy defaults, an ephemeral suite, migrations on.
    /// `storedNotesPath` picks the two shapes an upgrade comes in — the setting
    /// naming the legacy folder, or no setting at all with the app's old
    /// default in force (where the bundle markers are the earlier-install
    /// evidence the move needs).
    private func migratingStore(
        legacyName: String,
        storedNotesPath: Bool
    ) throws -> (store: SettingsStore, suite: UserDefaults, legacy: URL, target: URL, untouched: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SettingsStoreMigration-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent(legacyName, isDirectory: true)
        let target = root.appendingPathComponent("AppSupport-Notes", isDirectory: true)
        let untouched = root.appendingPathComponent("Documents-Unused", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "# Standup".write(to: legacy.appendingPathComponent("2026-08-01-standup.md"),
                              atomically: true, encoding: .utf8)

        let suite = makeSuite()
        if storedNotesPath {
            suite.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)
        } else {
            suite.set(true, forKey: "didMigrateFromOnTheSpot")
            suite.set(true, forKey: "didMigrateFromOpenGranola")
        }
        let store = SettingsStore(storage: SettingsStorage(
            defaults: suite,
            secretStore: .ephemeral,
            defaultNotesDirectory: target,
            legacyNotesDirectories: [legacy, untouched],
            runMigrations: true
        ))
        return (store, suite, legacy, target, untouched)
    }

    /// The launch-path invariant with the migrations actually running — the
    /// path that *can* break it. Nothing outside this test's own directories is
    /// read, so this is the upgrade case end to end.
    func testInitWithMigrationsMovesTheLegacyFolderAndCreatesNothingElse() async throws {
        let f = try migratingStore(legacyName: "Documents-Lore", storedNotesPath: false)

        XCTAssertEqual(f.store.notesFolderPath, f.target.path)
        let migrated = await waitUntil { f.suite.bool(forKey: NotesFolderMigration.markerKey) }
        XCTAssertTrue(migrated, "the move runs after launch, but it does run")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.target.appendingPathComponent("2026-08-01-standup.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.legacy.path), "moved, not copied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.untouched.path),
                       "a legacy folder that was not in use is never created")
    }

    /// The 2026-08-07 field failure, pinned: `init` used to move the folder
    /// inline and blocked there for minutes on iCloud-evicted files.
    ///
    /// The assertion is an ordering one, and exact rather than timed:
    /// `notesFolderPath` is read once in `init`, and the only thing that can
    /// change it afterwards is the move's repoint, which runs on the main actor
    /// — the actor this test holds until it awaits. Seeing the *old* path here
    /// means `init` returned without the move; the new one would mean it waited.
    func testInitReturnsBeforeTheMoveAndRepointsWhenItLands() async throws {
        let f = try migratingStore(legacyName: "Documents-OpenGranola", storedNotesPath: true)

        XCTAssertEqual(f.store.notesFolderPath, f.legacy.path,
                       "init returned with the pre-move path: it did not wait for the move")

        let repointed = await waitUntil { f.store.notesFolderPath == f.target.path }
        XCTAssertTrue(repointed, "the move lands off the launch path and repoints the setting")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.target.appendingPathComponent("2026-08-01-standup.md").path))
        XCTAssertTrue(f.suite.bool(forKey: NotesFolderMigration.markerKey))
    }

    func testLiveStorageDefaultsToTheAppsOwnFolder() {
        let storage = SettingsStorage.live(defaults: makeSuite())
        XCTAssertEqual(storage.defaultNotesDirectory, NotesFolder.applicationSupportDefault)
        XCTAssertEqual(storage.legacyNotesDirectories, NotesFolder.legacyDefaults)
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
