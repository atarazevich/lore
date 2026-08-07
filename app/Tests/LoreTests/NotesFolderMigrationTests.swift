import XCTest
@testable import LoreKit

/// The one-time notes move (#148) decides between five situations, and one of
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

    /// Decision and move back to back on one thread. The app never does this —
    /// it decides at launch and moves in the background — but composing them
    /// here is what makes the decision table assertable in one expression.
    /// `nil` means the decision settled without a move; the branch it took is
    /// then read off the trace, which is where the app reads it too.
    ///
    /// `duringRepoint` runs inside the move's main-actor repoint, i.e. in the
    /// window between the last file moving and the source folder going.
    private func run(
        target: URL,
        legacyDefaults: [URL],
        duringRepoint: @escaping @Sendable @MainActor () -> Void = {}
    ) async -> NotesFolderMigration.Result? {
        guard let move = NotesFolderMigration.decide(
            defaults: defaults, target: target, legacyDefaults: legacyDefaults
        ) else { return nil }
        return await move.perform(repoint: { _ in duringRepoint() })
    }

    private func lastDisposition() -> DiagEvent.NotesMigration? {
        let record = DiagStore.shared.last {
            if case .notesFolderMigrated = $0.event { return true } else { return false }
        }
        guard case .notesFolderMigrated(let disposition, _, _, _, _) = record?.event else { return nil }
        return disposition
    }

    // MARK: - Fresh install: the folder is never even looked at

    /// The whole reason #148 exists. A brand-new install has no stored path and
    /// no trace of an earlier launch, so the legacy folder must not be read —
    /// even here, where it is deliberately full. Reading it on a real machine
    /// is the Documents dialog at first launch.
    func testFreshInstallLeavesTheLegacyFolderAloneEntirely() async throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")

        let result = await run(target: target, legacyDefaults: [legacy])

        XCTAssertNil(result, "no move: nothing about a fresh install may be looked up on disk")
        XCTAssertEqual(lastDisposition(), .freshInstall)
        XCTAssertEqual(names(in: legacy), ["2026-08-01-standup.md"],
                       "a fresh install must not move, create or read anything in the legacy folder")
        XCTAssertFalse(exists(target), "nothing is created at launch — the folder appears on first use")
        XCTAssertNil(defaults.string(forKey: NotesFolderMigration.notesPathKey),
                     "no stored path: the live default already points at the app's domain")
        XCTAssertTrue(defaults.bool(forKey: NotesFolderMigration.markerKey),
                      "the decision is made once; a relaunch must not re-probe")
    }

    // MARK: - The old default, with content

    func testOldDefaultMovesEverythingAndRepointsTheSetting() async throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "# Standup")
        try makeFile("2026-08-01_10-30.m4a", in: legacy, contents: "audio-bytes")
        try makeFile(NotesFolder.spotlightSentinel, in: legacy, contents: "")
        // No stored path — the app's own default was in force — plus evidence
        // that an earlier version ran here.
        defaults.set(true, forKey: "didMigrateFromOpenGranola")

        let landed = await run(target: target, legacyDefaults: [legacy])
        let result = try XCTUnwrap(landed)

        XCTAssertEqual(result, .init(disposition: .moved, moved: 2))
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
    func testStoredLegacyPathMigratesAndCountsAsPriorInstallEvidence() async throws {
        let oldDefault = directory("Documents-Lore")
        let openGranola = directory("Documents-OpenGranola")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-03-27-database-import.md", in: openGranola, contents: "old notes")
        defaults.set(openGranola.path, forKey: NotesFolderMigration.notesPathKey)

        let landed = await run(target: target, legacyDefaults: [oldDefault, openGranola])
        let result = try XCTUnwrap(landed)

        XCTAssertEqual(result, .init(disposition: .moved, moved: 1))
        XCTAssertFalse(exists(openGranola))
        XCTAssertFalse(exists(oldDefault), "the folder that was not in use is not created either")
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), target.path)
    }

    /// The bundle-migration markers are the widest evidence there is — every
    /// build since the first one sets them on every launch, including builds
    /// predating onboarding. They are also written by `SettingsStore.init`
    /// itself, which is why the notes migration decides before them; this pins
    /// that each one alone is enough to look.
    func testEachPriorLaunchMarkerAloneCountsAsEvidence() async throws {
        for key in ["didMigrateFromOnTheSpot", "didMigrateFromOpenGranola",
                    "hasCompletedOnboarding", "hasAcknowledgedRecordingConsent"] {
            defaults.removePersistentDomain(forName: suiteName)
            let legacy = directory("Documents-Lore-\(key)")
            let target = directory("AppSupport-Notes-\(key)")
            try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
            defaults.set(true, forKey: key)

            let result = await run(target: target, legacyDefaults: [legacy])

            XCTAssertEqual(result, .init(disposition: .moved, moved: 1),
                           "\(key) must count as an earlier install")
        }
    }

    /// The stored string and the computed default are built by different code
    /// paths; a trailing slash must not read as "the user picked this".
    func testATrailingSlashStillReadsAsTheLegacyDefault() async throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        defaults.set(legacy.path + "/", forKey: NotesFolderMigration.notesPathKey)

        let result = await run(target: target, legacyDefaults: [legacy])

        XCTAssertEqual(result?.disposition, .moved)
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), target.path,
                       "and the repoint still recognizes the value it is replacing")
    }

    func testPriorInstallWithNoLegacyFolderJustRepointsTheSetting() async {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        defaults.set(true, forKey: "hasAcknowledgedRecordingConsent")

        let result = await run(target: target, legacyDefaults: [legacy])

        XCTAssertEqual(result?.disposition, .nothingToMove)
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), target.path)
        XCTAssertFalse(exists(target), "still nothing created at launch")
    }

    // MARK: - A folder the user picked

    func testCustomPathIsRespectedAndNeverRead() async throws {
        let legacy = directory("Documents-Lore")
        let custom = directory("Dropbox-Meetings")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        try makeFile("2026-08-02-review.md", in: custom, contents: "custom notes")
        defaults.set(custom.path, forKey: NotesFolderMigration.notesPathKey)

        let result = await run(target: target, legacyDefaults: [legacy])

        XCTAssertNil(result)
        XCTAssertEqual(lastDisposition(), .customPathRespected)
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), custom.path,
                       "a chosen folder stays chosen")
        XCTAssertEqual(names(in: custom), ["2026-08-02-review.md"],
                       "not moved, and not even a sentinel written into it")
        XCTAssertEqual(names(in: legacy), ["2026-08-01-standup.md"])
        XCTAssertFalse(exists(target))
        XCTAssertTrue(defaults.bool(forKey: NotesFolderMigration.markerKey))
    }

    /// The app's own folder is never traced as the user's choice. Reached by a
    /// launch killed in the gap between the move's repoint and its marker.
    func testTheAppsOwnFolderIsNotMistakenForAChosenOne() async {
        let target = directory("AppSupport-Notes")
        defaults.set(target.path, forKey: NotesFolderMigration.notesPathKey)

        let result = await run(target: target, legacyDefaults: [directory("Documents-Lore")])

        XCTAssertNil(result)
        XCTAssertEqual(lastDisposition(), .alreadyAtTarget)
        XCTAssertTrue(defaults.bool(forKey: NotesFolderMigration.markerKey))
    }

    // MARK: - Target already exists

    /// Also the resume case: a killed move can leave the target holding a
    /// truncated copy under the right name, and no-overwrite turns that into
    /// two surviving copies rather than a good file replaced by a broken one.
    func testNameCollisionKeepsBothCopiesAndFlagsTheLeftover() async throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "legacy copy")
        try makeFile("2026-08-03-onboarding.md", in: legacy, contents: "only in legacy")
        try makeFile("2026-08-01-standup.md", in: target, contents: "target copy")
        defaults.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)

        let landed = await run(target: target, legacyDefaults: [legacy])
        let result = try XCTUnwrap(landed)

        XCTAssertEqual(result, .init(disposition: .moved, moved: 1, leftBehind: 1))
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
    func testSentinelAndDSStoreDoNotKeepTheSourceAlive() async throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        try makeFile(".DS_Store", in: legacy, contents: "finder")
        try makeFile(NotesFolder.spotlightSentinel, in: legacy, contents: "")
        defaults.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)

        let result = await run(target: target, legacyDefaults: [legacy])

        XCTAssertEqual(result?.moved, 1)
        XCTAssertFalse(exists(legacy))
    }

    // MARK: - iCloud placeholders

    /// The 2026-08-07 field failure: moving a file with no local bytes out of a
    /// synced folder makes macOS download it first, for minutes. Such an entry
    /// is left where it is, counted apart from a collision because it needs a
    /// different remedy, and surfaced through the leftover row.
    func testEvictedEntriesAreLeftBehindAndNeverDownloaded() async throws {
        let legacy = directory("Documents-OpenGranola")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "local")
        // How iCloud parks an evicted file: a hidden placeholder sibling.
        let evicted = try makeFile(".2026-03-27-huge-meeting.m4a.icloud", in: legacy, contents: "stub")
        defaults.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)

        let landed = await run(target: target, legacyDefaults: [legacy])
        let result = try XCTUnwrap(landed)

        XCTAssertEqual(result, .init(disposition: .moved, moved: 1, evicted: 1))
        XCTAssertTrue(exists(evicted), "an evicted file is never pulled down, and never moved")
        XCTAssertEqual(names(in: target), ["2026-08-01-standup.md", NotesFolder.spotlightSentinel],
                       "the file with bytes on this Mac still lands")
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), target.path)

        // The row names the folder and, because the cause is eviction, gets the
        // remedy that never suggests deleting anything.
        XCTAssertEqual(NotesFolderMigration.verifyLeftover(defaults: defaults),
                       NotesLeftover(path: legacy.path, hasEvicted: true))
    }

    // MARK: - Ordering: setting first, folder second

    /// The landing order in one test. The repoint runs on the main actor before
    /// the source folder goes, so a note written in that window is aimed at the
    /// new folder — and the removal is `rmdir`, which refuses a non-empty
    /// directory instead of deleting what is in it.
    func testAStragglerWrittenDuringTheRepointSurvivesAndIsFlagged() async throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        defaults.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)
        let straggler = legacy.appendingPathComponent("2026-08-05-written-mid-move.md")

        let landed = await run(target: target, legacyDefaults: [legacy], duringRepoint: {
            try? "landed in the gap".write(to: straggler, atomically: true, encoding: .utf8)
        })
        let result = try XCTUnwrap(landed)

        XCTAssertEqual(result, .init(disposition: .moved, moved: 1))
        XCTAssertEqual(try String(contentsOf: straggler, encoding: .utf8), "landed in the gap",
                       "rmdir refuses a non-empty folder; a recursive delete would have eaten this")
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.leftoverKey), legacy.path,
                       "and the refusal is what makes the straggler visible instead of orphaned")
    }

    /// A folder chosen in Settings while the move runs wins. The move can take
    /// minutes and the app is usable throughout, so the repoint is decided on
    /// the main actor against the value the *decision* saw — not applied blind.
    func testAFolderPickedDuringTheMoveIsNotOverwritten() async throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        let chosen = directory("Dropbox-Meetings")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        defaults.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)

        let move = try XCTUnwrap(NotesFolderMigration.decide(
            defaults: defaults, target: target, legacyDefaults: [legacy]))
        // The user opens Settings and picks a folder while the move is running.
        defaults.set(chosen.path, forKey: NotesFolderMigration.notesPathKey)

        await move.perform(repoint: { _ in })

        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), chosen.path)
        XCTAssertTrue(exists(legacy),
                      "and the folder is left standing rather than removed under a setting "
                          + "that no longer points at its replacement")
    }

    // MARK: - Idempotence

    /// The launch path decides; it does not touch the folder, write the marker
    /// or repoint the setting. That is what makes a launch killed mid-move
    /// decide identically next time and finish the job, rather than believing
    /// it is done.
    func testDecidingTouchesNothingAndLeavesNoMarker() async throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        defaults.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)

        XCTAssertNotNil(NotesFolderMigration.decide(
            defaults: defaults, target: target, legacyDefaults: [legacy]))

        XCTAssertFalse(defaults.bool(forKey: NotesFolderMigration.markerKey),
                       "the marker follows the move, not the decision")
        XCTAssertEqual(names(in: legacy), ["2026-08-01-standup.md"])
        XCTAssertFalse(exists(target))
        XCTAssertEqual(defaults.string(forKey: NotesFolderMigration.notesPathKey), legacy.path)
    }

    func testSecondRunMovesNothingEvenIfTheFolderRefills() async throws {
        let legacy = directory("Documents-Lore")
        let target = directory("AppSupport-Notes")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        defaults.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)
        await run(target: target, legacyDefaults: [legacy])

        try makeFile("2026-08-04-later.md", in: legacy, contents: "written after the move")
        let second = await run(target: target, legacyDefaults: [legacy])

        XCTAssertNil(second, "decided once; a relaunch does not look again")
        XCTAssertEqual(names(in: legacy), ["2026-08-04-later.md"])
    }

    // MARK: - Leftovers: marker at launch, verified when the panel opens

    /// The launch read is the marker and nothing else. The folder it names sits
    /// in `~/Documents`, and `HealthMonitor.init` probes at launch — reading it
    /// there would be the TCC touch this change exists to remove.
    func testLaunchReadNeverOpensTheLeftoverFolder() throws {
        let legacy = directory("Documents-Lore")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "still here")
        XCTAssertNil(NotesFolderMigration.pendingLeftover(defaults: defaults))

        defaults.set(legacy.path, forKey: NotesFolderMigration.leftoverKey)
        XCTAssertEqual(NotesFolderMigration.pendingLeftover(defaults: defaults),
                       NotesLeftover(path: legacy.path, hasEvicted: false))

        // Emptied behind the app's back: the marker still reports, because the
        // launch read is not allowed to check. Only `verifyLeftover` may.
        try FileManager.default.removeItem(at: legacy.appendingPathComponent("2026-08-01-standup.md"))
        XCTAssertEqual(NotesFolderMigration.pendingLeftover(defaults: defaults)?.path, legacy.path)
    }

    func testPanelReadVerifiesAndClearsItsOwnMarker() throws {
        let legacy = directory("Documents-Lore")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "still here")
        defaults.set(legacy.path, forKey: NotesFolderMigration.leftoverKey)
        defaults.set(true, forKey: NotesFolderMigration.leftoverEvictedKey)

        XCTAssertEqual(NotesFolderMigration.verifyLeftover(defaults: defaults),
                       NotesLeftover(path: legacy.path, hasEvicted: false),
                       "the cause is re-derived from the folder, not recalled from the marker")

        try FileManager.default.removeItem(at: legacy.appendingPathComponent("2026-08-01-standup.md"))
        XCTAssertNil(NotesFolderMigration.verifyLeftover(defaults: defaults),
                     "the row withdraws itself once the condition clears")
        XCTAssertNil(defaults.string(forKey: NotesFolderMigration.leftoverKey),
                     "and clears its own marker, so it cannot re-fire")
        XCTAssertNil(defaults.object(forKey: NotesFolderMigration.leftoverEvictedKey))
    }

    // MARK: - Trace

    /// A migration that runs once and cannot be re-run has to stay answerable
    /// from events.json afterwards — including the branches that moved nothing.
    func testEveryDecidingBranchLeavesADiagnosticEvent() async throws {
        let cases: [(DiagEvent.NotesMigration, () -> Void)] = [
            (.freshInstall, {}),
            (.customPathRespected, { self.defaults.set("/tmp/elsewhere", forKey: NotesFolderMigration.notesPathKey) }),
            (.nothingToMove, { self.defaults.set(true, forKey: "hasCompletedOnboarding") }),
        ]
        for (expected, arrange) in cases {
            defaults.removePersistentDomain(forName: suiteName)
            arrange()
            await run(target: directory("AppSupport-Notes"), legacyDefaults: [directory("Documents-Lore")])

            XCTAssertEqual(lastDisposition(), expected)
        }
    }

    /// The start of a move is traced too: one that blocks — a directory of
    /// iCloud placeholders is accepted as able to — leaves this and no
    /// completion, and that difference is the only way to tell it from a launch
    /// that had nothing to do (`no-false-positives.md` §5).
    func testTheMoveTracesItsStartWithTheEntryCount() async throws {
        let legacy = directory("Documents-Lore")
        try makeFile("2026-08-01-standup.md", in: legacy, contents: "notes")
        try makeFile("2026-08-02-review.md", in: legacy, contents: "notes")
        defaults.set(legacy.path, forKey: NotesFolderMigration.notesPathKey)

        await run(target: directory("AppSupport-Notes"), legacyDefaults: [legacy])

        let record = DiagStore.shared.last {
            if case .notesFolderMoveStarted = $0.event { return true } else { return false }
        }
        guard case .notesFolderMoveStarted(let entries) = try XCTUnwrap(record?.event) else {
            return XCTFail("expected a notesFolderMoveStarted event")
        }
        XCTAssertEqual(entries, 2)
    }

    // MARK: - The default location itself

    func testDefaultNotesDirectoryLivesInsideApplicationSupport() {
        let path = NotesFolder.applicationSupportDefault.path
        XCTAssertTrue(path.hasSuffix("/Library/Application Support/Lore/Notes"), path)
        XCTAssertFalse(path.contains("/Documents/"),
                       "the app's data must not live in a TCC-protected folder")
    }
}
