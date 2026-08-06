import XCTest
@testable import LoreKit

/// Review-chat semantics (#62): a completed exchange persists to the file of
/// the session it was asked in — even if the user switched away before the
/// answer landed — while the switch keeps it out of the newly shown view.
@MainActor
final class AskLoreChatModelTests: XCTestCase {

    private var repo: SessionRepository!

    override func setUp() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LoreAskLoreChatModelTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = SessionRepository(rootDirectory: root)
        // chat.json lands inside an existing session directory — seed both.
        await repo.seedSession(id: "session_A", records: [], startedAt: Date())
        await repo.seedSession(id: "session_B", records: [], startedAt: Date())
    }

    /// Mirrors NotesView.rewireReviewChat: the persistence hook captures the
    /// session ID at bind time.
    private func wire(_ model: AskLoreChatModel, to sessionID: String) {
        let repo = repo!
        model.onExchange = { question, answer in
            let exchange = ChatExchange(question: question, answer: answer)
            Task {
                await repo.appendChatExchange(sessionID: sessionID, exchange: exchange)
            }
        }
    }

    func testExchangeAppendsToTheBoundSessionFile() async throws {
        let model = AskLoreChatModel(isLive: false, ask: { _, _, _, _, _ in "The answer." })
        wire(model, to: "session_A")
        model.loadPersistedHistory([])

        model.send(question: "What was agreed?", transcript: "You: hi", apiKey: "key")
        try await Task.sleep(for: .milliseconds(200))

        let chatA = await repo.loadChat(sessionID: "session_A")
        XCTAssertEqual(chatA.count, 1)
        XCTAssertEqual(chatA[0].question, "What was agreed?")
        XCTAssertEqual(chatA[0].answer, "The answer.")
        let chatB = await repo.loadChat(sessionID: "session_B")
        XCTAssertTrue(chatB.isEmpty)

        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages[0].role, .user)
        XCTAssertEqual(model.messages[1].role, .assistant)
        XCTAssertEqual(model.messages[1].text, "The answer.")
    }

    func testSessionSwitchPersistsInFlightAnswerToOriginFileOnly() async throws {
        // finish() is sticky: the for-await loop ends whenever it runs.
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        let model = AskLoreChatModel(isLive: false, ask: { _, _, _, _, _ in
            for await _ in gate {}
            return "Late answer for A."
        })

        // Asking in session A…
        wire(model, to: "session_A")
        model.loadPersistedHistory([])
        model.send(question: "Still there?", transcript: "You: hi", apiKey: "key")
        XCTAssertTrue(model.isThinking)

        // …then switching to session B while the answer is in flight.
        model.loadPersistedHistory([ChatExchange(question: "Earlier?", answer: "Yes.")])
        wire(model, to: "session_B")

        release.finish()
        try await Task.sleep(for: .milliseconds(200))

        // The exchange landed in its ORIGIN session's file (the hook was
        // captured at send time, bound to A)…
        let chatA = await repo.loadChat(sessionID: "session_A")
        XCTAssertEqual(chatA.count, 1)
        XCTAssertEqual(chatA[0].question, "Still there?")
        XCTAssertEqual(chatA[0].answer, "Late answer for A.")

        // …and neither the answer nor the file write touched session B.
        XCTAssertEqual(model.messages.count, 2, "only session B's persisted turns")
        XCTAssertFalse(model.messages.contains { $0.text.contains("Late answer") })
        let chatB = await repo.loadChat(sessionID: "session_B")
        XCTAssertTrue(chatB.isEmpty)
    }

    func testLoadPersistedHistoryFlattensExchangesAndClearsThinking() {
        let model = AskLoreChatModel(isLive: false, ask: { _, _, _, _, _ in "unused" })
        model.loadPersistedHistory([
            ChatExchange(question: "Q1", answer: "A1"),
            ChatExchange(question: "Q2", answer: "A2"),
        ])

        XCTAssertEqual(model.messages.map(\.text), ["Q1", "A1", "Q2", "A2"])
        XCTAssertEqual(
            model.messages.map(\.role),
            [.user, .assistant, .user, .assistant]
        )
        XCTAssertFalse(model.isThinking)
    }
}
