import XCTest
@testable import LoreKit

/// The #150 gate: the flag itself, and the migration that must never send a
/// configured machine back through onboarding — nor keep a machine that was
/// never set up out of the flow.
final class SetupStateTests: XCTestCase {

    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "com.lore.test.setup.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Fresh install

    func testEmptyDomainIsNotComplete() {
        XCTAssertFalse(SetupState.resolve(defaults: defaults))
    }

    /// The verdict is written down on the first launch too, so the next launch
    /// reads the flag rather than re-deriving it from keys the new flow no
    /// longer writes.
    func testFreshInstallPersistsFalse() {
        _ = SetupState.resolve(defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: SetupState.completedKey) as? Bool, false)
    }

    // MARK: - Migration from the retired flags

    /// The dictation flow is the one that actually collected the permissions,
    /// so on its own it means this machine is set up.
    func testDictationOnboardingAloneMigratesToComplete() {
        defaults.set(true, forKey: SetupState.dictationCompletedKey)
        XCTAssertTrue(SetupState.resolve(defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: SetupState.completedKey))
    }

    /// The old 2-step meetings tour granted nothing and configured nothing. A
    /// machine carrying only its flag has no permissions and belongs in the new
    /// flow — treating the tour as a completed setup is how a fresh-ish install
    /// ends up in the app with no microphone access.
    func testTourAloneStillNeedsSetup() {
        defaults.set(true, forKey: SetupState.tourCompletedKey)
        XCTAssertFalse(SetupState.resolve(defaults: defaults))
    }

    /// Consent alone is no evidence either: nothing in the old app collected a
    /// permission on the way to that sheet.
    func testConsentAloneStillNeedsSetup() {
        defaults.set(true, forKey: SetupState.consentAcknowledgedKey)
        XCTAssertFalse(SetupState.resolve(defaults: defaults))
    }

    /// The owner's machine and every other real install: tour plus consent is a
    /// machine that went through both of the old gates. An update that
    /// re-onboarded a daily user would read as a factory reset.
    func testTourPlusConsentMigratesToComplete() {
        defaults.set(true, forKey: SetupState.tourCompletedKey)
        defaults.set(true, forKey: SetupState.consentAcknowledgedKey)
        XCTAssertNil(defaults.object(forKey: SetupState.completedKey))
        XCTAssertTrue(SetupState.resolve(defaults: defaults))
    }

    /// A machine that carries the legacy keys as *false* is one that launched an
    /// older build and never finished — it belongs in the new flow.
    func testLegacyKeysAllFalseStaysIncomplete() {
        for key in SetupState.legacyCompletionKeys {
            defaults.set(false, forKey: key)
        }
        XCTAssertFalse(SetupState.resolve(defaults: defaults))
    }

    /// Migration runs once. An explicit stored value always wins afterwards, so
    /// a user who somehow lands back in setup is not dragged out of it by a
    /// stale legacy key.
    func testStoredFlagWinsOverLegacyKeys() {
        defaults.set(true, forKey: SetupState.dictationCompletedKey)
        defaults.set(false, forKey: SetupState.completedKey)
        XCTAssertFalse(SetupState.resolve(defaults: defaults))
    }

    /// The legacy keys survive the migration: `NotesFolderMigration` reads two
    /// of them as its "an earlier launch happened here" evidence, and deleting
    /// them would make an upgraded install look factory-fresh to that decision.
    func testMigrationDoesNotDeleteLegacyKeys() {
        defaults.set(true, forKey: SetupState.tourCompletedKey)
        defaults.set(true, forKey: SetupState.consentAcknowledgedKey)
        XCTAssertTrue(SetupState.resolve(defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: SetupState.tourCompletedKey))
        XCTAssertTrue(defaults.bool(forKey: SetupState.consentAcknowledgedKey))
    }

    // MARK: - Ordering against the notes migration (#148)

    /// Load-bearing: `NotesFolderMigration` recognizes a fresh install by the
    /// *absence* of prior-launch keys, and on that evidence decides whether to
    /// look inside `~/Documents` — the look *is* the consent dialog. Resolving
    /// the gate must therefore write nothing but its own key, or every fresh
    /// install would look like an upgrade to the notes move.
    ///
    /// Asserted by inspecting the domain rather than by running the migration:
    /// `NotesFolderMigration.run` records a `DiagEvent`, and its store is a
    /// singleton — a unit test asserts on the domain it owns.
    func testResolveWritesOnlyItsOwnKey() {
        _ = SetupState.resolve(defaults: defaults)

        let written = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(
            Set(written.keys), [SetupState.completedKey],
            "resolving the gate must not fabricate prior-launch evidence"
        )
    }
}
