import XCTest
@testable import LoreKit

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Meeting auto-enrichment (#107). The model-backed tests run the real
/// on-device model and skip when it is unavailable (macOS < 26, Apple
/// Intelligence off, assets not downloaded); the rest are model-free.
final class MeetingEnrichmentEngineTests: XCTestCase {

    private var root: URL!
    private var repo: SessionRepository!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EnrichmentTests-\(UUID().uuidString)", isDirectory: true)
        repo = SessionRepository(rootDirectory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Model-free

    func testSummaryPersistsThroughMetadataRoundTrip() async {
        await repo.seedSession(id: "session_a", records: transcript(), startedAt: .now)
        await repo.updateSessionSummary(sessionID: "session_a", summary: "Discussed the pilot scope.")

        let sessions = await repo.listSessions()
        XCTAssertEqual(sessions.first?.summary, "Discussed the pilot scope.")
    }

    func testEmptyTranscriptIsNeverEnriched() async {
        await repo.seedSession(id: "session_empty", records: [], startedAt: .now)
        let engine = MeetingEnrichmentEngine(repository: repo, onEnriched: {})

        await engine.enrichIfNeeded(sessionID: "session_empty")

        let sessions = await repo.listSessions()
        XCTAssertNil(sessions.first?.summary)
    }

    func testTagFilterDropsPronounsAndJunk() {
        // People as the model emitted them on a real long Russian
        // transcript (#131): "Я" and "Твоя" tagged as people.
        let filtered = MeetingEnrichmentEngine.filteredTags(
            ["Марина", "Я", "Твоя", " they ", "42", "K"]
        )
        XCTAssertEqual(filtered, ["Марина"])
    }

    func testRepositoryDedupesTagsCaseInsensitivelyFirstWins() async {
        // Dedupe against existing tags lives in the repository, not the
        // filter: the engine passes `existing + appended` and
        // `updateSessionTags` normalizes case-insensitively, first-wins.
        await repo.seedSession(id: "session_tags", records: transcript(), startedAt: .now)
        await repo.updateSessionTags(sessionID: "session_tags", tags: ["марина", "Марина", "Acme"])

        let tags = await repo.listSessions().first?.tags
        XCTAssertEqual(tags, ["марина", "Acme"])
    }

    // MARK: - On-device model (skips when unavailable)

    func testEnrichmentFillsTitleTagsAndSummary() async throws {
        try skipUnlessModelAvailable()

        let startedAt = Date()
        await repo.seedSession(
            id: "session_default_title",
            records: transcript(),
            startedAt: startedAt,
            title: SessionIndex.defaultTitle(startedAt: startedAt)
        )
        let refreshed = expectation(description: "onEnriched fired")
        let engine = MeetingEnrichmentEngine(repository: repo, onEnriched: { refreshed.fulfill() })

        await engine.enrichIfNeeded(sessionID: "session_default_title")
        await fulfillment(of: [refreshed], timeout: 1)

        let session = await repo.listSessions().first
        let summary = try XCTUnwrap(session?.summary)
        XCTAssertFalse(summary.isEmpty)
        // The untouched default title is replaced with a topical one.
        XCTAssertNotEqual(session?.title, SessionIndex.defaultTitle(startedAt: startedAt))
        XCTAssertNotNil(session?.title)
        // The type tag always lands.
        let tags = (session?.tags ?? []).map { $0.lowercased() }
        XCTAssertTrue(tags.contains("work") || tags.contains("personal"))
    }

    func testManualTitleIsNeverOverwritten() async throws {
        try skipUnlessModelAvailable()

        await repo.seedSession(
            id: "session_renamed",
            records: transcript(),
            startedAt: .now,
            title: "My hand-picked name"
        )
        let engine = MeetingEnrichmentEngine(repository: repo, onEnriched: {})

        await engine.enrichIfNeeded(sessionID: "session_renamed")

        let session = await repo.listSessions().first
        XCTAssertEqual(session?.title, "My hand-picked name")
        XCTAssertNotNil(session?.summary)
    }

    // MARK: - Helpers

    private func skipUnlessModelAvailable() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("FoundationModels requires macOS 26+")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("on-device model unavailable on this machine")
        }
        #else
        throw XCTSkip("SDK has no FoundationModels")
        #endif
    }

    private func transcript() -> [SessionRecord] {
        let start = Date()
        return [
            SessionRecord(
                speaker: .you,
                text: "Thanks for joining. I want to finalize the rollout plan for the Acme onboarding pilot.",
                timestamp: start
            ),
            SessionRecord(
                speaker: .them,
                text: "Sounds good. Anna said her team can start next Monday if we sign the contract this week.",
                timestamp: start.addingTimeInterval(30)
            ),
            SessionRecord(
                speaker: .you,
                text: "Then let's send Acme the contract today and schedule the kickoff with Anna for Monday.",
                timestamp: start.addingTimeInterval(60)
            ),
        ]
    }
}
