import XCTest
@testable import LoreKit

/// Storage migration and retention policy for dictation history (#51):
/// the single UserDefaults blob becomes per-entry JSON files, the 500 text
/// cap is gone, and audio retention prunes only the oldest AUDIO files.
@MainActor
final class DictationHistoryTests: XCTestCase {

    private var tempRoot: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    private var entriesDir: URL { tempRoot.appendingPathComponent("entries") }
    private var audioDir: URL { tempRoot.appendingPathComponent("audio") }

    override func setUp() {
        super.setUp()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DictationHistoryTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "com.lore.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func makeHistory() -> DictationHistory {
        DictationHistory(defaults: defaults, entriesDirectory: entriesDir, audioDirectory: audioDir)
    }

    private func makeEntry(
        timestamp: Date, rawText: String, audioFilename: String? = nil
    ) -> DictationHistoryEntry {
        var entry = DictationHistoryEntry(
            timestamp: timestamp, durationSeconds: 2.0, audioFilename: audioFilename
        )
        entry.status = .transcribed
        entry.rawText = rawText
        return entry
    }

    /// Creates a fake audio file in the injected audio dir and returns its name.
    private func writeAudioFile(_ name: String, bytes: [UInt8] = [1, 2, 3, 4]) throws -> String {
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try Data(bytes).write(to: audioDir.appendingPathComponent(name))
        return name
    }

    // MARK: - Migration (UserDefaults blob → per-entry files)

    func testMigratesLegacyBlobToPerEntryFiles() throws {
        let original = [
            makeEntry(timestamp: Date(timeIntervalSince1970: 2000), rawText: "newest"),
            makeEntry(timestamp: Date(timeIntervalSince1970: 1000), rawText: "oldest",
                      audioFilename: "a.raw"),
        ]
        let blob = try JSONEncoder().encode(original)
        defaults.set(blob, forKey: "dictationHistory")
        let audioBytes: [UInt8] = [9, 8, 7, 6, 5]
        _ = try writeAudioFile("a.raw", bytes: audioBytes)

        let history = makeHistory()

        // Content identical after migration (Equatable covers every field).
        XCTAssertEqual(history.entries, original)
        // One file per entry on disk.
        let files = try FileManager.default.contentsOfDirectory(atPath: entriesDir.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, 2)
        // The raw blob survives byte-identical under the backup key; the
        // legacy key is cleared so migration never re-runs.
        XCTAssertEqual(defaults.data(forKey: DictationHistory.legacyBackupKey), blob)
        XCTAssertNil(defaults.data(forKey: "dictationHistory"))
        // Audio untouched, byte-identical.
        XCTAssertEqual(
            try Data(contentsOf: audioDir.appendingPathComponent("a.raw")), Data(audioBytes)
        )
    }

    func testUndecodableLegacyBlobIsLeftInPlace() {
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: "dictationHistory")

        let history = makeHistory()

        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "dictationHistory"), garbage)
        XCTAssertNil(defaults.data(forKey: DictationHistory.legacyBackupKey))
    }

    /// When entry files cannot be written (here: the entries path is blocked
    /// by a file, so the directory can't exist), migration must NOT clear
    /// the legacy key — it stays authoritative and retries next launch, and
    /// this session still serves every entry from the blob.
    func testMigrationAbortsAndKeepsLegacyBlobWhenWritesFail() throws {
        let original = [
            makeEntry(timestamp: Date(timeIntervalSince1970: 2000), rawText: "two"),
            makeEntry(timestamp: Date(timeIntervalSince1970: 1000), rawText: "one"),
        ]
        let blob = try JSONEncoder().encode(original)
        defaults.set(blob, forKey: "dictationHistory")

        // Block the entries directory: a regular FILE at its parent path
        // makes createDirectory and every entry write fail.
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data().write(to: entriesDir)

        let history = makeHistory()

        // Legacy key intact (migration will retry), no backup written yet.
        XCTAssertEqual(defaults.data(forKey: "dictationHistory"), blob)
        XCTAssertNil(defaults.data(forKey: DictationHistory.legacyBackupKey))
        // Nothing disappears meanwhile: entries served from the blob.
        XCTAssertEqual(history.entries, original)
        // The failed writes are surfaced, not silent.
        XCTAssertNotNil(history.lastSaveError)
    }

    // MARK: - Per-entry persistence

    func testEntriesSurviveReloadNewestFirst() {
        let history = makeHistory()
        let older = makeEntry(timestamp: Date(timeIntervalSince1970: 100), rawText: "older")
        let newer = makeEntry(timestamp: Date(timeIntervalSince1970: 200), rawText: "newer")
        history.add(older)
        history.add(newer)

        var updated = older
        updated.cleanedText = "Older."
        updated.activeVersion = .cleaned
        history.update(updated)

        let reloaded = makeHistory()
        XCTAssertEqual(reloaded.entries, [newer, updated])
    }

    /// Clear = everything: entry files AND the legacy blob/backup keys, so
    /// no later launch can resurrect deleted entries.
    func testClearRemovesEntryFilesAndLegacyKeys() throws {
        let seeded = [makeEntry(timestamp: Date(timeIntervalSince1970: 50), rawText: "legacy")]
        defaults.set(try JSONEncoder().encode(seeded), forKey: "dictationHistory")
        let history = makeHistory() // migrates → backup key now set
        history.add(makeEntry(timestamp: Date(), rawText: "x"))

        history.clear()

        XCTAssertTrue(history.entries.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: entriesDir.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertTrue(files.isEmpty)
        XCTAssertNil(defaults.data(forKey: "dictationHistory"))
        XCTAssertNil(defaults.data(forKey: DictationHistory.legacyBackupKey))
        XCTAssertTrue(makeHistory().entries.isEmpty)
    }

    func testRevisionBumpsOnMutation() {
        let history = makeHistory()
        let start = history.revision
        let entry = makeEntry(timestamp: Date(), rawText: "x")
        history.add(entry)
        XCTAssertEqual(history.revision, start + 1)
        history.update(entry)
        XCTAssertEqual(history.revision, start + 2)
    }

    // MARK: - Retention: no text cap, audio-only pruning past 500

    func testAppendPast500KeepsTextAndPrunesOldestAudioOnly() throws {
        let history = makeHistory()
        let total = 502

        for i in 0..<total {
            let name = try writeAudioFile("audio-\(i).raw")
            history.add(makeEntry(
                timestamp: Date(timeIntervalSince1970: Double(i)),
                rawText: "entry \(i)",
                audioFilename: name
            ))
        }

        // Every text entry survives — no 500-entry cap.
        XCTAssertEqual(history.entries.count, total)
        XCTAssertEqual(history.entries.last?.rawText, "entry 0")

        // The two oldest recordings lost only their audio.
        let withAudio = history.entries.filter { $0.audioFilename != nil }
        XCTAssertEqual(withAudio.count, 500)
        XCTAssertNil(history.entries.last?.audioFilename)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("audio-0.raw").path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("audio-1.raw").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("audio-2.raw").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("audio-501.raw").path)
        )

        // The nilled audioFilename is persisted, not just in memory.
        let reloaded = makeHistory()
        XCTAssertNil(reloaded.entries.last?.audioFilename)
        XCTAssertEqual(reloaded.entries.filter { $0.audioFilename != nil }.count, 500)
    }

    // MARK: - Configurable audio retention (#52)

    func testConfigurableRetentionLimitRespectedAtAdd() throws {
        let history = makeHistory()
        history.audioRetentionLimit = 2

        for i in 0..<3 {
            let name = try writeAudioFile("audio-\(i).raw")
            history.add(makeEntry(
                timestamp: Date(timeIntervalSince1970: Double(i)),
                rawText: "entry \(i)",
                audioFilename: name
            ))
        }

        // The third-oldest recording lost only its audio; text is intact.
        XCTAssertEqual(history.entries.count, 3)
        XCTAssertEqual(history.entries.last?.rawText, "entry 0")
        XCTAssertNil(history.entries.last?.audioFilename)
        XCTAssertEqual(history.entries.filter { $0.audioFilename != nil }.count, 2)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("audio-0.raw").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("audio-1.raw").path)
        )
    }

    /// Lowering the setting prunes immediately via `pruneAudio(keeping:)` —
    /// no need to wait for the next dictation.
    func testPruneAudioKeepingPrunesImmediatelyAndPersists() throws {
        let history = makeHistory()
        history.audioRetentionLimit = 10
        for i in 0..<3 {
            let name = try writeAudioFile("audio-\(i).raw")
            history.add(makeEntry(
                timestamp: Date(timeIntervalSince1970: Double(i)),
                rawText: "entry \(i)",
                audioFilename: name
            ))
        }
        XCTAssertEqual(history.entries.filter { $0.audioFilename != nil }.count, 3)
        let revisionBefore = history.revision

        history.pruneAudio(keeping: 1)

        XCTAssertEqual(history.entries.filter { $0.audioFilename != nil }.count, 1)
        XCTAssertEqual(history.entries.first?.audioFilename, "audio-2.raw")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("audio-0.raw").path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("audio-1.raw").path)
        )
        // Views observing the revision counter refresh.
        XCTAssertEqual(history.revision, revisionBefore + 1)
        // The new limit governs subsequent adds too.
        XCTAssertEqual(history.audioRetentionLimit, 1)
        // Text rows all survive, and the nilled filenames are persisted.
        let reloaded = makeHistory()
        XCTAssertEqual(reloaded.entries.count, 3)
        XCTAssertEqual(reloaded.entries.filter { $0.audioFilename != nil }.count, 1)
    }

    /// 0 is the unlimited sentinel: nothing is pruned even past the old
    /// hardcoded 500, at add-time or via the immediate prune.
    func testZeroLimitKeepsAllAudioPast500() throws {
        let history = makeHistory()
        history.audioRetentionLimit = 0
        let total = 502

        for i in 0..<total {
            let name = try writeAudioFile("audio-\(i).raw")
            history.add(makeEntry(
                timestamp: Date(timeIntervalSince1970: Double(i)),
                rawText: "entry \(i)",
                audioFilename: name
            ))
        }

        XCTAssertEqual(history.entries.filter { $0.audioFilename != nil }.count, total)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("audio-0.raw").path)
        )

        history.pruneAudio(keeping: 0)
        XCTAssertEqual(history.entries.filter { $0.audioFilename != nil }.count, total)
    }
}
