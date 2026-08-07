import XCTest
@testable import LoreKit

/// The one-time notes move (#148) decides between four situations, and one of
/// them — a fresh install — is defined by what it must NOT do: look inside
/// `~/Documents`. Every case here runs against temp directories, so the real
/// folders are never an input and the "did not touch" assertions are real
/// assertions rather than a promise.
final class NotesFolderMigrationTests: XCTestCase {

    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("NotesFolderMigrationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "com.lore.tests.notesmove.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func directory(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    @discardableResult
    private func makeFile(_ name: String, in directory: URL, contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func names(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func run(target: URL, legacyDefaults: [URL]) -> NotesFolderMigration.Result {
        NotesFolderMigration.run(defaults: defaults, target: target, legacyDefaults: legacyDefaults)
    }

    // MARK: - Fresh install: the folder is never even looked at

    /// The whole reason #148 exists. A brand-new install has no stored path and
    /// no trace of an earlier launch, so the legacy folder must not be read —
    /// even here, where it is deliberately full. Reading it on a real machine
    /// is the Documents dialog at first launch.
    func testFreshInstallLeavesTheLegacyFolderAloneEntirely() throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")

        let result = run(target: target, legacyDefaults: [legacy])

        XCTAssertEqual(result.disposition, .freshInstall)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(names(in: legacy), ["2026-08-01-standup.md"],
                       "a fresh install must not move, create or read anything in the legacy folder")
        XCTAssertFalse(exists(target), "nothing is created at launch — the folder appears on first use")
        XCTAssertNil(defaults.string(forKey: NotesFolderMigration.notesPathKey),
                     "no stored path: the live default already points at the app's domain")
        XCTAssertTrue(defaults.bool(forKey: NotesFolderMigration.markerKey),
                      "the decision is made once; a relaunch must not re-probe")
    }

    // MARK: - The old default, with content

    func testOldDefaultMovesEverythingAndRepointsTheSetting() throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "# Standup")
        try makeFile("2026-08-01_10-30.m4a", in: legacy, contents: "audio-bytes")
        try makeFile(NotesFolder.spotlightSentinel, in: legacy, contents: "")
        // No stored path — the app's own default was in force — plus evidence
        // that an earlier version ran here.
        defaults.set(true, forKey: "didMigrateFromOpenGranola")

        let result = run(target: target, legacyDefaults: [legacy])

        XCTAssertEqual(result.disposition, .moved)
        XCTAssertEqual(result.moved, 2)
        XCTAssertEqual(result.leftBehind, 0)
        XCTAssertEqual(result.unverified, 0)
        XCTAssertFalse(exists(legacy), "move, not copy: nothing is left in Documents")
        XCTAssertEqual(names(in: target),
                       ["2026-08-01-standup.md", "2026-08-01_10-30.m4a", NotesFolder.spotlightSentinel])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("2026-08-01-standup.md"),
                                  encoding: .utf8), "# Standup")
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), target.path)
        XCTAssertNil(defaults.string(forKey: NotesFolderMigration.leftoverKey))
    }

    /// A stored path that the *app* wrote there (the OpenGranola migration set
    /// `notesFolderPath` itself) is a default, not a choice, and moves too.
    func testStoredLegacyPathMigratesAndCountsAsPriorInstallEvidence() throws {
        let oldDefault = directory("Documents-Lore")
        let openGranola = directory("Documents-OpenGranola")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-03-27-database-import.md", in: openGranola, contents: "old notes")
        defaults.set(openGranola.path, forKey: NotesFolderMigration.notesPathKey)

        let result = run(target: target, legacyDefaults: [oldDefault, openGranola])

        XCTAssertEqual(result.disposition, .moved)
        XCTAssertEqual(result.moved, 1)
        XCTAssertFalse(exists(openGranola))
        XCTAssertFalse(exists(oldDefault), "the folder that was not in use is not created either")
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), target.path)
    }

    /// The bundle-migration markers are the widest evidence there is — every
    /// build since the first one sets them on every launch, including builds
    /// predating onboarding. They are also written by `SettingsStore.init`
    /// itself, which is why the notes migration runs before them; this pins
    /// that each one alone is enough to look.
    func testEachPriorLaunchMarkerAloneCountsAsEvidence() throws {
        for key in ["didMigrateFromOnTheSpot", "didMigrateFromOpenGranola",
                    "hasCompletedOnboarding", "hasAcknowledgedRecordingConsent"] {
            defaults.removePersistentDomain(forName: suiteName)
            let legacy = directory("Documents-Lore-\(key)")
            let target = directory("AppSupport-Notes-\(key)")
            try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
            defaults.set(true, forKey: key)

            let result = run(target: target, legacyDefaults: [legacy])

            XCTAssertEqual(result.disposition, .moved, "\(key) must count as an earlier install")
            XCTAssertEqual(result.moved, 1, key)
        }
    }

    /// The stored string and the computed default are built by different code
    /// paths; a trailing slash must not read as "the user picked this".
    func testATrailingSlashStillReadsAsTheLegacyDefault() throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        defaults.set(legacy.path + "/", forKey: NotesFolderMigration.notesPathKey)

        XCTAssertEqual(run(target: target, legacyDefaults: [legacy]).disposition, .moved)
    }

    func testPriorInstallWithNoLegacyFolderJustRepointsTheSetting() {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        defaults.set(true, forKey: "hasAcknowledgedRecordingConsent")

        let result = run(target: target, legacyDefaults: [legacy])

        XCTAssertEqual(result.disposition, .nothingToMove)
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), target.path)
        XCTAssertFalse(exists(target), "still nothing created at launch")
    }

    // MARK: - A folder the user picked

    func testCustomPathIsRespectedAndNeverRead() throws {
        let legacy = directory("Documents-Lore")
        let custom = directory("Dropbox-Meetings")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        try makeFile("2026-08-02-review.md", in: custom, contents: "custom notes")
        defaults.set(custom.path, forKey: NotesFolderMigration.notesPathKey)

        let result = run(target: target, legacyDefaults: [legacy])

        XCTAssertEqual(result.disposition, .customPathRespected)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), custom.path,
                       "a chosen folder stays chosen")
        XCTAssertEqual(names(in: custom), ["2026-08-02-review.md"],
                       "not moved, and not even a sentinel written into it")
        XCTAssertEqual(names(in: legacy), ["2026-08-01-standup.md"])
        XCTAssertFalse(exists(target))
        XCTAssertTrue(defaults.bool(forKey: NotesFolderMigration.markerKey))
    }

    // MARK: - Target already exists

    func testNameCollisionKeepsBothCopiesAndFlagsTheLeftover() throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "legacy copy")
        try makeFile("2026-08-03-onboarding.md", in: legacy, contents: "only in legacy")
        try makeFile("2026-08-01-standup.md", in: target, contents: "target copy")
        defaults.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)

        let result = run(target: target, legacyDefaults: [legacy])

        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.leftBehind, 1)
        XCTAssertTrue(exists(legacy), "a folder that still holds data is never removed")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("2026-08-01-standup.md"),
                                  encoding: .utf8), "target copy",
                       "nothing in the target is overwritten")
        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("2026-08-01-standup.md"),
                                  encoding: .utf8), "legacy copy",
                       "and nothing in the source is deleted — both copies survive")
        XCTAssertTrue(exists(target.appendingPathComponent("2026-08-03-onboarding.md")))
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.leftoverKey), legacy.path)
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), target.path)
    }

    /// Finder's and our own droppings are not user data, so they must not keep
    /// an otherwise-emptied folder alive in Documents.
    func testSentinelAndDSStoreDoNotKeepTheSourceAlive() throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        try makeFile(".DS_Store", in: legacy, contents: "finder")
        try makeFile(NotesFolder.spotlightSentinel, in: legacy, contents: "")
        defaults.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)

        let result = run(target: target, legacyDefaults: [legacy])

        XCTAssertEqual(result.moved, 1)
        XCTAssertFalse(exists(legacy))
    }

    // MARK: - Idempotence

    func testSecondRunMovesNothingEvenIfTheFolderRefills() throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        defaults.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)
        run(target: target, legacyDefaults: [legacy])

        try makeFile("2026-08-04-later.md", in: legacy, contents: "written after the move")
        let second = run(target: target, legacyDefaults: [legacy])

        XCTAssertEqual(second.disposition, .alreadyDone)
        XCTAssertEqual(second.moved, 0)
        XCTAssertEqual(names(in: legacy), ["2026-08-04-later.md"])
    }

    // MARK: - Leftovers: marker at launch, verified when the panel opens

    /// The launch read is the marker and nothing else. The folder it names sits
    /// in `~/Documents`, and `HealthMonitor.init` probes at launch — reading it
    /// there would be the TCC touch this change exists to remove.
    func testLaunchReadNeverOpensTheLeftoverFolder() throws {
        let legacy = directory("Documents-Lore")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "still here")
        XCTAssertNil(NotesFolderMigration.pendingLeftoverPath(defaults: defaults))

        defaults.set(legacy.path, forKey: NotesFolderMigration.leftoverKey)
        XCTAssertEqual(NotesFolderMigration.pendingLeftoverPath(defaults: defaults), legacy.path)

        // Emptied behind the app's back: the marker still reports, because the
        // launch read is not allowed to check. Only `verifyLeftover` may.
        try FileManager.default.removeItem(at: legacy.appendingPathComponent("2026-08-01-standup.md"))
        XCTAssertEqual(NotesFolderMigration.pendingLeftoverPath(defaults: defaults), legacy.path)
    }

    func testPanelReadVerifiesAndClearsItsOwnMarker() throws {
        let legacy = directory("Documents-Lore")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "still here")
        defaults.set(legacy.path, forKey: NotesFolderMigration.leftoverKey)

        XCTAssertEqual(NotesFolderMigration.verifyLeftover(defaults: defaults), legacy.path)

        try FileManager.default.removeItem(at: legacy.appendingPathComponent("2026-08-01-standup.md"))
        XCTAssertNil(NotesFolderMigration.verifyLeftover(defaults: defaults),
                     "the row withdraws itself once the condition clears")
        XCTAssertNil(defaults.string(forKey: NotesFolderMigration.leftoverKey),
                     "and clears its own marker, so it cannot re-fire")
    }

    // MARK: - Trace

    /// A migration that runs once and cannot be re-run has to stay answerable
    /// from events.json afterwards — including the branches that moved nothing.
    func testEveryDecidingBranchLeavesADiagnosticEvent() throws {
        let cases: [(DiagEvent.NotesMigration, () -> Void)] = [
            (.freshInstall, {}),
            (.customPathRespected, { self.defaults.set("/tmp/elsewhere", forKey: NotesFolderMigration.notesPathKey) }),
            (.nothingToMove, { self.defaults.set(true, forKey: "hasCompletedOnboarding") }),
        ]
        for (expected, arrange) in cases {
            defaults.removePersistentDomain(forName: suiteName)
            arrange()
            run(target: directory("AppSupport-Notes"), legacyDefaults: [directory("Documents-Lore")])

            let record = DiagStore.shared.last { if case .notesFolderMigrated = $0.event { return true } else { return false } }
            guard case .notesFolderMigrated(let disposition, _, _, _) = try XCTUnwrap(record?.event) else {
                return XCTFail("expected a notesFolderMigrated event for \(expected.rawValue)")
            }
            XCTAssertEqual(disposition, expected)
        }
    }

    // MARK: - The default location itself

    func testDefaultNotesDirectoryLivesInsideApplicationSupport() {
        let path = NotesFolder.applicationSupportDefault.path
        XCTAssertTrue(path.hasSuffix("/Library/Application Support/Lore/Notes"), path)
        XCTAssertFalse(path.contains("/Documents/"),
                       "the app's data must not live in a TCC-protected folder")
    }
}
