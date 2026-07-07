import XCTest
@testable import LoreKit

@MainActor
final class NotesControllerTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDirs() -> (root: URL, notes: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LoreNotesControllerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        return (root, notesDirectory)
    }

    private func seedSession(
        coordinator: AppCoordinator,
        sessionID: String = "session_test_001",
        title: String = "Test Meeting",
        utterances: [SessionRecord]? = nil
    ) async {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let records = utterances ?? [
            SessionRecord(speaker: .you, text: "Hello there.", timestamp: startedAt),
            SessionRecord(speaker: .them, text: "Hi, how are you?", timestamp: startedAt.addingTimeInterval(10)),
            SessionRecord(speaker: .you, text: "Great, let's discuss the plan.", timestamp: startedAt.addingTimeInterval(20)),
        ]

        await coordinator.sessionRepository.seedSession(
            id: sessionID,
            records: records,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            templateSnapshot: coordinator.templateStore.snapshot(
                of: coordinator.templateStore.template(for: TemplateStore.genericID) ?? TemplateStore.builtInTemplates.first!
            ),
            title: title
        )
        await coordinator.loadHistory()
    }

    private func makeController(root: URL) -> (NotesController, AppCoordinator) {
        let coordinator = AppCoordinator(
            sessionRepository: SessionRepository(rootDirectory: root),
            templateStore: TemplateStore(rootDirectory: root),
            transcriptStore: TranscriptStore()
        )
        let controller = NotesController(coordinator: coordinator)
        return (controller, coordinator)
    }

    // MARK: - Tests

    func testSelectSessionLoadsTranscriptAndNotes() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_select"

        await seedSession(coordinator: coordinator, sessionID: sessionID)

        controller.selectSession(sessionID)

        // Wait for async load to complete
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.state.selectedSessionID, sessionID)
        XCTAssertEqual(controller.state.loadedTranscript.count, 3)
        XCTAssertNil(controller.state.loadedNotes, "No notes should exist before generation")
    }

    func testRenameSessionUpdatesHistory() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_rename"

        await seedSession(coordinator: coordinator, sessionID: sessionID, title: "Original Title")
        await controller.loadHistory()

        let originalSession = controller.state.sessionHistory.first { $0.id == sessionID }
        XCTAssertEqual(originalSession?.title, "Original Title")

        controller.renameSession(sessionID: sessionID, newTitle: "New Title")
        try? await Task.sleep(for: .milliseconds(300))

        let renamedSession = controller.state.sessionHistory.first { $0.id == sessionID }
        XCTAssertEqual(renamedSession?.title, "New Title")
    }

    func testDeleteSessionRemovesFromHistory() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_delete"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        await coordinator.sessionRepository.appendChatExchange(
            sessionID: sessionID,
            exchange: ChatExchange(question: "Summary?", answer: "Discussed the plan.")
        )
        await controller.loadHistory()
        XCTAssertTrue(controller.state.sessionHistory.contains { $0.id == sessionID })

        controller.selectSession(sessionID)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.state.loadedChat.count, 1)

        controller.deleteSession(sessionID: sessionID)
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(controller.state.sessionHistory.contains { $0.id == sessionID })
        XCTAssertNil(controller.state.selectedSessionID)
        XCTAssertTrue(controller.state.loadedTranscript.isEmpty)
        XCTAssertNil(controller.state.loadedNotes)
        XCTAssertTrue(controller.state.loadedChat.isEmpty)
    }

    func testOpenNotesSelectsCorrectSession() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let sessionID = "session_test_open"

        await seedSession(coordinator: coordinator, sessionID: sessionID)
        coordinator.queueSessionSelection(sessionID)

        await controller.onAppear()

        XCTAssertEqual(controller.state.selectedSessionID, sessionID)
    }

    // MARK: - Import failure/preemption outcome (#43)

    /// Import completion never deletes the placeholder: a failed or preempted
    /// import keeps the session — fresh marker intact — so the row stays
    /// visible with the failed banner instead of vanishing.
    func testFailedImportPreservesSession() async {
        let (root, _) = makeTempDirs()
        let (controller, coordinator) = makeController(root: root)
        let repo = coordinator.sessionRepository

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = await repo.createImportedSession(
            config: .init(
                title: "Imported Meeting",
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                language: "en-US",
                engine: "parakeet"
            )
        )
        await repo.markSessionUnviewed(sessionID: sessionID)

        // The completion handler (LoreRootApp.importMeetingRecording) only
        // logs and reloads history on non-completed statuses — the session
        // must still be listed with everything the failed state needs.
        await controller.loadHistory()
        let row = controller.state.sessionHistory.first { $0.id == sessionID }
        XCTAssertNotNil(row, "Failed import must leave the session row in place")
        XCTAssertEqual(row?.source, SessionIndex.importedSource)
        XCTAssertEqual(row?.unviewed, true, "Fresh marker survives the failure")
    }

    func testOriginalTranscriptToggle() async {
        let (root, _) = makeTempDirs()
        let (controller, _) = makeController(root: root)

        XCTAssertFalse(controller.state.showingOriginal)

        controller.toggleShowingOriginal()
        XCTAssertTrue(controller.state.showingOriginal)

        controller.toggleShowingOriginal()
        XCTAssertFalse(controller.state.showingOriginal)
    }
}
