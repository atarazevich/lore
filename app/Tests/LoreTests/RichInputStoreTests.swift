import XCTest
@testable import LoreKit

/// The images collected during a dictation are kept under a size ceiling
/// (#196): oldest deleted first, the folder never above the cap, and an
/// entry's files go when the entry does.
final class RichInputStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoreRichInputTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func stored(_ name: String, bytes: Int64, ageSeconds: Double) -> RichInputStore.StoredImage {
        RichInputStore.StoredImage(
            url: directory.appendingPathComponent(name),
            bytes: bytes,
            written: Date(timeIntervalSince1970: 1_000_000 - ageSeconds)
        )
    }

    /// One image per entry, written `ageSeconds` ago. Returns its file name.
    @discardableResult
    private func writeImage(
        entryID: UUID = UUID(), index: Int = 0, bytes: Int, ageSeconds: Double
    ) throws -> String {
        let url = directory.appendingPathComponent("\(entryID.uuidString)-\(index).png")
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: url.path
        )
        return url.lastPathComponent
    }

    private var names: Set<String> {
        Set(RichInputStore.contents(of: directory).map { $0.url.lastPathComponent })
    }

    // MARK: - The order and the arithmetic

    func testOldestGoFirstAndOnlyAsFarAsTheCap() {
        let files = [
            stored("newest.png", bytes: 400, ageSeconds: 0),
            stored("oldest.png", bytes: 400, ageSeconds: 300),
            stored("middle.png", bytes: 400, ageSeconds: 100),
        ]
        XCTAssertEqual(
            RichInputStore.pruneList(files, limitBytes: 900).map { $0.url.lastPathComponent },
            ["oldest.png"]
        )
        XCTAssertEqual(
            RichInputStore.pruneList(files, limitBytes: 500).map { $0.url.lastPathComponent },
            ["oldest.png", "middle.png"]
        )
        // A folder that already fits loses nothing — including an empty one.
        XCTAssertTrue(RichInputStore.pruneList(files, limitBytes: 1200).isEmpty)
        XCTAssertTrue(RichInputStore.pruneList([], limitBytes: 100).isEmpty)
    }

    // MARK: - Against a real folder

    func testTheFolderEndsUnderTheCapAndTheNewestSurvive() throws {
        let oldest = try writeImage(bytes: 500_000, ageSeconds: 300)
        let middle = try writeImage(bytes: 500_000, ageSeconds: 200)
        let newest = try writeImage(bytes: 500_000, ageSeconds: 100)
        // Nothing this store wrote: never counted, never deleted.
        try Data(count: 900_000).write(to: directory.appendingPathComponent("notes.txt"))

        RichInputStore.pruneToCap(limitMegabytes: 1, directory: directory)

        XCTAssertEqual(names, [middle, newest])
        XCTAssertFalse(names.contains(oldest))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("notes.txt").path
        ))
        let total = RichInputStore.contents(of: directory).reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertLessThanOrEqual(total, 1_048_576)

        // Nothing left to do: a second pass over a folder that fits.
        RichInputStore.pruneToCap(limitMegabytes: 1, directory: directory)
        XCTAssertEqual(names.count, 2)
    }

    /// 0 is the unlimited sentinel, exactly as in Keep audio — never
    /// "keep zero bytes".
    func testAZeroCapDeletesNothing() throws {
        try writeImage(bytes: 2_000_000, ageSeconds: 10)
        RichInputStore.pruneToCap(limitMegabytes: 0, directory: directory)
        XCTAssertEqual(names.count, 1)
    }

    // MARK: - Whose file is whose

    func testTheFileNameCarriesItsEntry() {
        let id = UUID()
        XCTAssertEqual(
            RichInputStore.entryID(of: URL(fileURLWithPath: "/x/\(id.uuidString)-11.png")), id
        )
        XCTAssertNil(RichInputStore.entryID(of: URL(fileURLWithPath: "/x/screenshot.png")))
        XCTAssertNil(RichInputStore.entryID(of: URL(fileURLWithPath: "/x/not-a-uuid-1.png")))
    }

    func testDeletingEntriesTakesTheirImagesAndNobodyElses() throws {
        let kept = UUID()
        let gone = UUID()
        let keptImage = try writeImage(entryID: kept, bytes: 10, ageSeconds: 0)
        try writeImage(entryID: gone, index: 0, bytes: 10, ageSeconds: 0)
        try writeImage(entryID: gone, index: 1, bytes: 10, ageSeconds: 0)

        RichInputStore.deleteFiles(ofEntries: [gone], directory: directory)

        XCTAssertEqual(names, [keptImage])
    }

    /// Clearing history takes the collected images with it — nothing outlives
    /// the row that pointed at it.
    @MainActor
    func testClearingHistoryDeletesTheCollectedImages() throws {
        let entriesDirectory = directory.appendingPathComponent("entries", isDirectory: true)
        let audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
        let images = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let suiteName = "RichInputStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let history = DictationHistory(
            defaults: defaults,
            entriesDirectory: entriesDirectory,
            audioDirectory: audioDirectory,
            richInputDirectory: images
        )
        let entry = DictationHistoryEntry(durationSeconds: 1)
        history.add(entry)
        let image = images.appendingPathComponent("\(entry.id.uuidString)-0.png")
        try Data(count: 10).write(to: image)

        history.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
    }
}
