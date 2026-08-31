import Foundation
import XCTest
@testable import LoreKit

/// Cleanup and translation never touch inserted material (#192, D5): only the
/// spoken words go to the model, and what was inserted comes back byte for
/// byte — paths, quotes, markdown and all.
@MainActor
final class RichInputCleanupTests: XCTestCase {

    // `pasteText` reads the Copying switches live (#198), and the composed text
    // these tests assert on is built from it — on this machine the owner's own
    // Settings would otherwise decide whether they pass.
    override func setUp() async throws {
        _ = isolatedRichInputDefaults("RichInputCleanupTests")
    }

    override func tearDown() async throws {
        RichInputSettings.use(.standard)
    }

    private func makeCoordinator(_ client: LoudCleanupClient) -> DictationCoordinator {
        let name = "com.lore.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RichInputCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let coordinator = DictationCoordinator(
            history: DictationHistory(
                defaults: defaults,
                entriesDirectory: tmp.appendingPathComponent("entries"),
                audioDirectory: tmp.appendingPathComponent("audio")
            ),
            cleanupClient: client
        )
        coordinator.settings = isolatedSettings("RichInputCleanupTests", apiKey: "sk-test")
        return coordinator
    }

    private func entryCarrying(
        _ items: [DictationItem], spoken: String, words: [RichInput.Word]
    ) -> DictationHistoryEntry {
        var entry = DictationHistoryEntry(durationSeconds: 40)
        entry.status = .transcribed
        entry.items = items
        entry.rawText = RichInput.compose(spoken: spoken, items: items, words: words)
        return entry
    }

    func testOnlyTheSpokenWordsReachTheModel() async {
        let client = LoudCleanupClient()
        let coordinator = makeCoordinator(client)
        let item = DictationItem(kind: .text, offset: 0.5, text: "**Dated path** — every dot")
        var entry = entryCarrying(
            [item], spoken: "one two three",
            words: spokenWords([0.5, 1.0, 1.5], endingClauseAt: [0])
        )

        let cleaned = await coordinator.cleanupEntry(
            &entry, rawText: entry.rawText!, prompt: "clean it", endpoint: .cleanup
        )

        XCTAssertTrue(cleaned)
        XCTAssertEqual(client.seen.sorted(), ["one", "two three"])
        XCTAssertEqual(
            entry.cleanedText,
            """
            ONE

            <copied>
            **Dated path** — every dot
            </copied>

            TWO THREE
            """
        )
    }

    func testAPathSurvivesTheCleanupUntouched() async {
        let client = LoudCleanupClient()
        let coordinator = makeCoordinator(client)
        let path = "/Users/a/Library/Application Support/Lore/RichInput/x-0.png"
        let item = DictationItem(kind: .image, offset: 0.5, path: path)
        var entry = entryCarrying(
            [item], spoken: "look at that",
            words: spokenWords([0.5, 1.0, 1.5], endingClauseAt: [0])
        )

        _ = await coordinator.cleanupEntry(
            &entry, rawText: entry.rawText!, prompt: "clean it", endpoint: .cleanup
        )

        XCTAssertEqual(
            entry.cleanedText, "LOOK\n\n<screenshot>\(path)</screenshot>\n\nAT THAT"
        )
        XCTAssertFalse(client.seen.contains { $0.contains(path) })
    }

    /// A dictation that carried nothing is one call, exactly as before.
    func testATextWithNoItemsIsOneCall() async {
        let client = LoudCleanupClient()
        let coordinator = makeCoordinator(client)
        var entry = DictationHistoryEntry(durationSeconds: 4)
        entry.status = .transcribed
        entry.rawText = "one two three"

        _ = await coordinator.cleanupEntry(
            &entry, rawText: entry.rawText!, prompt: "clean it", endpoint: .cleanup
        )

        XCTAssertEqual(client.seen, ["one two three"])
        XCTAssertEqual(entry.cleanedText, "ONE TWO THREE")
    }

    /// An item switched off never travelled, so it is not in the text and not
    /// in what the model sees.
    func testAnItemLeftOutIsNowhereInTheCleanup() async {
        let client = LoudCleanupClient()
        let coordinator = makeCoordinator(client)
        var item = DictationItem(kind: .text, offset: 0.5, text: "COPIED")
        item.included = false
        var entry = entryCarrying(
            [item], spoken: "one two", words: spokenWords([0.5, 1.0], endingClauseAt: [0])
        )

        _ = await coordinator.cleanupEntry(
            &entry, rawText: entry.rawText!, prompt: "clean it", endpoint: .cleanup
        )

        XCTAssertEqual(entry.rawText, "one two")
        XCTAssertEqual(client.seen, ["one two"])
        XCTAssertEqual(entry.cleanedText, "ONE TWO")
    }
}
