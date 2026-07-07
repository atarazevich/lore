import XCTest
@testable import LoreKit

final class SessionRepositoryTests: XCTestCase {

    private var repo: SessionRepository!
    private var rootDir: URL!

    override func setUp() async throws {
        rootDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LoreRepoTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        repo = SessionRepository(rootDirectory: rootDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootDir)
        repo = nil
    }

    // MARK: - startSession creates canonical directory layout

    func testStartSessionCreatesDirectoryLayout() async {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID

        let sessionsDir = rootDir.appendingPathComponent("sessions", isDirectory: true)
        let sessionDir = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("session.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("transcript.live.jsonl").path
        ))

        await repo.endSession()
        await repo.deleteSession(sessionID: sessionID)
    }

    func testStartSessionSetsCurrentID() async {
        let handle = await repo.startSession()
        let id = await repo.getCurrentSessionID()
        XCTAssertNotNil(id)
        XCTAssertEqual(id, handle.sessionID)
        XCTAssertTrue(id!.hasPrefix("session_"))

        await repo.endSession()
        await repo.deleteSession(sessionID: handle.sessionID)
    }

    // MARK: - appendLiveUtterance writes to JSONL

    func testAppendLiveUtteranceWritesToJSONL() async {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID

        let utterance = Utterance(text: "Hello from test", speaker: .them, timestamp: Date())
        await repo.appendLiveUtterance(sessionID: sessionID, utterance: utterance)
        await repo.endSession()

        let transcript = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(transcript.count, 1)
        XCTAssertEqual(transcript.first?.text, "Hello from test")
        XCTAssertEqual(transcript.first?.speaker, .them)

        await repo.deleteSession(sessionID: sessionID)
    }

    func testAppendMultipleUtterances() async {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID

        for i in 1...5 {
            let utterance = Utterance(
                text: "Utterance \(i)",
                speaker: i.isMultiple(of: 2) ? .you : .them,
                timestamp: Date()
            )
            await repo.appendLiveUtterance(sessionID: sessionID, utterance: utterance)
        }
        await repo.endSession()

        let transcript = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(transcript.count, 5)
        XCTAssertEqual(transcript[0].text, "Utterance 1")
        XCTAssertEqual(transcript[4].text, "Utterance 5")

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - finalizeSession writes session.json

    func testFinalizeSessionWritesMetadata() async {
        // Title set at creation (#58) must survive finalization.
        let handle = await repo.startSession(
            config: SessionStartConfig(title: "Test Meeting")
        )
        let sessionID = handle.sessionID
        let startDate = Date()

        let utterance = Utterance(text: "Test", speaker: .you, timestamp: startDate)
        await repo.appendLiveUtterance(sessionID: sessionID, utterance: utterance)

        await repo.finalizeSession(
            sessionID: sessionID,
            metadata: SessionFinalizeMetadata(
                endedAt: Date(),
                utteranceCount: 1,
                language: "fr-FR",
                meetingApp: "Zoom",
                engine: "parakeetV2",
                templateSnapshot: nil,
                utterances: [utterance]
            )
        )

        let sessions = await repo.listSessions()
        let found = sessions.first(where: { $0.id == sessionID })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "Test Meeting")
        XCTAssertEqual(found?.language, "fr-FR")
        XCTAssertEqual(found?.meetingApp, "Zoom")
        XCTAssertEqual(found?.engine, "parakeetV2")
        XCTAssertEqual(found?.utteranceCount, 1)
        XCTAssertNotNil(found?.endedAt)

        await repo.deleteSession(sessionID: sessionID)
    }

    /// A rename during the recording must not be overwritten by finalization.
    func testFinalizeSessionPreservesMidRecordingRename() async {
        let handle = await repo.startSession(
            config: SessionStartConfig(title: "Thu 03:01")
        )
        let sessionID = handle.sessionID

        await repo.renameSession(sessionID: sessionID, title: "Pilot kickoff")

        let utterance = Utterance(text: "Test", speaker: .you, timestamp: Date())
        await repo.appendLiveUtterance(sessionID: sessionID, utterance: utterance)
        let index = await repo.finalizeSession(
            sessionID: sessionID,
            metadata: SessionFinalizeMetadata(
                endedAt: Date(),
                utteranceCount: 1,
                language: nil,
                meetingApp: nil,
                engine: nil,
                templateSnapshot: nil,
                utterances: [utterance]
            )
        )

        XCTAssertEqual(index.title, "Pilot kickoff")
        let sessions = await repo.listSessions()
        XCTAssertEqual(sessions.first(where: { $0.id == sessionID })?.title, "Pilot kickoff")

        await repo.deleteSession(sessionID: sessionID)
    }

    /// Display-only fallback (#58): sessions without a stored title render
    /// the derived "Weekday HH:MM" name, never "Untitled". No migration.
    func testDisplayTitleFallsBackToDerivedName() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let index = SessionIndex(
            id: "s1", startedAt: startedAt, endedAt: nil,
            templateSnapshot: nil, title: nil, utteranceCount: 0,
            hasNotes: false, language: nil, meetingApp: nil, engine: nil
        )
        XCTAssertEqual(index.displayTitle, SessionIndex.defaultTitle(startedAt: startedAt))
        XCTAssertFalse(index.displayTitle.isEmpty)

        let named = SessionIndex(
            id: "s2", startedAt: startedAt, endedAt: nil,
            templateSnapshot: nil, title: "Named", utteranceCount: 0,
            hasNotes: false, language: nil, meetingApp: nil, engine: nil
        )
        XCTAssertEqual(named.displayTitle, "Named")
    }

    /// defaultTitle uses Date.FormatStyle; pin that its shape matches the
    /// DateFormatter "EEEjmm" template it replaced, across a 12h and a 24h
    /// locale (e.g. "Tue 10:13 PM" / "Вт 22:13").
    func testDefaultTitleStyleMatchesTemplateAcrossLocales() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for identifier in ["en_US", "ru_RU"] {
            let locale = Locale(identifier: identifier)

            let template = DateFormatter()
            template.locale = locale
            template.setLocalizedDateFormatFromTemplate("EEEjmm")

            let style = Date.FormatStyle(locale: locale)
                .weekday(.abbreviated).hour().minute()

            XCTAssertEqual(
                date.formatted(style),
                template.string(from: date),
                "FormatStyle output diverged from the EEEjmm template for \(identifier)"
            )
        }
    }

    // MARK: - saveNotes writes both files

    func testSaveNotesWritesBothFiles() async {
        let sessionID = "test_notes_session"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Hello", timestamp: Date())],
            startedAt: Date()
        )

        let template = TemplateSnapshot(
            id: UUID(), name: "Test", icon: "star", systemPrompt: "Be helpful"
        )
        let notes = EnhancedNotes(
            template: template,
            generatedAt: Date(),
            markdown: "# Test Notes\n\nContent here."
        )

        await repo.saveNotes(sessionID: sessionID, notes: notes)

        let sessionsDir = rootDir.appendingPathComponent("sessions", isDirectory: true)
        let sessionDir = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("notes.md").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("notes.meta.json").path
        ))

        let loaded = await repo.loadNotes(sessionID: sessionID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.markdown, "# Test Notes\n\nContent here.")
        XCTAssertEqual(loaded?.template.name, "Test")

        // hasNotes should be updated in session.json
        let sessions = await repo.listSessions()
        let found = sessions.first(where: { $0.id == sessionID })
        XCTAssertEqual(found?.hasNotes, true)

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - listSessions returns all sessions

    func testListSessionsReturnsAllSessions() async {
        await repo.seedSession(
            id: "session_a",
            records: [SessionRecord(speaker: .you, text: "A", timestamp: Date())],
            startedAt: Date(timeIntervalSinceNow: -100)
        )
        await repo.seedSession(
            id: "session_b",
            records: [SessionRecord(speaker: .them, text: "B", timestamp: Date())],
            startedAt: Date()
        )

        let sessions = await repo.listSessions()
        XCTAssertTrue(sessions.contains(where: { $0.id == "session_a" }))
        XCTAssertTrue(sessions.contains(where: { $0.id == "session_b" }))

        // Should be sorted newest first
        if let aIdx = sessions.firstIndex(where: { $0.id == "session_a" }),
           let bIdx = sessions.firstIndex(where: { $0.id == "session_b" }) {
            XCTAssertLessThan(bIdx, aIdx)
        }

        await repo.deleteSession(sessionID: "session_a")
        await repo.deleteSession(sessionID: "session_b")
    }

    // MARK: - loadSession returns transcript and notes

    func testLoadSessionReturnsTranscriptAndNotes() async {
        let sessionID = "session_load_test"
        let records = [
            SessionRecord(speaker: .you, text: "First", timestamp: Date()),
            SessionRecord(speaker: .them, text: "Second", timestamp: Date()),
        ]

        let template = TemplateSnapshot(
            id: UUID(), name: "Generic", icon: "doc", systemPrompt: "Notes"
        )
        let notes = EnhancedNotes(
            template: template,
            generatedAt: Date(),
            markdown: "# Notes"
        )

        await repo.seedSession(
            id: sessionID,
            records: records,
            startedAt: Date(),
            notes: notes
        )

        let detail = await repo.loadSession(id: sessionID)
        XCTAssertEqual(detail.transcript.count, 2)
        XCTAssertEqual(detail.transcript[0].text, "First")
        XCTAssertNotNil(detail.notes)
        XCTAssertEqual(detail.notes?.markdown, "# Notes")

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - renameSession updates metadata

    func testRenameSessionUpdatesMetadata() async {
        let sessionID = "session_rename_test"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Hi", timestamp: Date())],
            startedAt: Date(),
            title: "Original"
        )

        await repo.renameSession(sessionID: sessionID, title: "Renamed")

        let sessions = await repo.listSessions()
        let found = sessions.first(where: { $0.id == sessionID })
        XCTAssertEqual(found?.title, "Renamed")

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - deleteSession removes directory

    func testDeleteSessionRemovesDirectory() async {
        let sessionID = "session_delete_test"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Delete me", timestamp: Date())],
            startedAt: Date()
        )

        let before = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertFalse(before.isEmpty)

        await repo.deleteSession(sessionID: sessionID)

        let after = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertTrue(after.isEmpty)

        let sessions = await repo.listSessions()
        XCTAssertFalse(sessions.contains(where: { $0.id == sessionID }))
    }

    // MARK: - Legacy sessions readable

    func testLegacySessionsReadable() async {
        // Create a legacy-format session: flat .jsonl + .meta.json in sessions/
        let sessionsDir = rootDir.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let sessionID = "session_2025-01-15_10-00-00"

        // Write legacy JSONL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = SessionRecord(
            speaker: .them, text: "Legacy hello",
            timestamp: Date(timeIntervalSince1970: 1_705_312_800)
        )
        let jsonlData = try! encoder.encode(record)
        let jsonlContent = String(data: jsonlData, encoding: .utf8)! + "\n"
        let jsonlURL = sessionsDir.appendingPathComponent("\(sessionID).jsonl")
        try! jsonlContent.write(to: jsonlURL, atomically: true, encoding: .utf8)

        // Write legacy sidecar
        let sidecar = SessionSidecar(
            index: SessionIndex(
                id: sessionID,
                startedAt: Date(timeIntervalSince1970: 1_705_312_800),
                title: "Legacy Meeting",
                utteranceCount: 1,
                hasNotes: false
            ),
            notes: nil
        )
        let sidecarData = try! encoder.encode(sidecar)
        let sidecarURL = sessionsDir.appendingPathComponent("\(sessionID).meta.json")
        try! sidecarData.write(to: sidecarURL)

        // Verify legacy session appears in listing
        let sessions = await repo.listSessions()
        let found = sessions.first(where: { $0.id == sessionID })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "Legacy Meeting")

        // Verify transcript loads
        let transcript = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(transcript.count, 1)
        XCTAssertEqual(transcript.first?.text, "Legacy hello")

        // Cleanup
        try? FileManager.default.removeItem(at: jsonlURL)
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    // MARK: - FileHandle stays open during recording

    func testFileHandleStaysOpenDuringRecording() async {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID

        // Write multiple utterances - FileHandle should remain open
        for i in 1...10 {
            let utterance = Utterance(text: "Message \(i)", speaker: .you, timestamp: Date())
            await repo.appendLiveUtterance(sessionID: sessionID, utterance: utterance)
        }

        // All should be written
        await repo.endSession()
        let transcript = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(transcript.count, 10)

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - exportPlainText

    func testExportPlainText() async {
        let sessionID = "session_export_test"
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)

        await repo.seedSession(
            id: sessionID,
            records: [
                SessionRecord(speaker: .you, text: "Hello there", timestamp: startDate),
                SessionRecord(speaker: .them, text: "Hi back", timestamp: startDate.addingTimeInterval(10)),
            ],
            startedAt: startDate
        )

        let text = await repo.exportPlainText(sessionID: sessionID)
        XCTAssertTrue(text.contains("Lore"))
        XCTAssertTrue(text.contains("You: Hello there"))
        XCTAssertTrue(text.contains("Them: Hi back"))

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - saveFinalTranscript

    func testSaveFinalTranscript() async {
        let sessionID = "session_final_test"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Live", timestamp: Date())],
            startedAt: Date()
        )

        let finalRecords = [
            SessionRecord(speaker: .you, text: "Final A", timestamp: Date()),
            SessionRecord(speaker: .them, text: "Final B", timestamp: Date()),
        ]
        await repo.saveFinalTranscript(sessionID: sessionID, records: finalRecords)

        // loadTranscript should prefer final
        let loaded = await repo.loadTranscript(sessionID: sessionID)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].text, "Final A")

        // loadLiveTranscript should still return original
        let live = await repo.loadLiveTranscript(sessionID: sessionID)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].text, "Live")

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - moveToRecentlyDeleted

    func testMoveToRecentlyDeleted() async {
        let sessionID = "session_soft_delete"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Hi", timestamp: Date())],
            startedAt: Date()
        )

        await repo.moveToRecentlyDeleted(sessionID: sessionID)

        let sessions = await repo.listSessions()
        XCTAssertFalse(sessions.contains(where: { $0.id == sessionID }))
    }

    // MARK: - End session clears state

    func testEndSessionClearsCurrentID() async {
        let handle = await repo.startSession()
        let id = await repo.getCurrentSessionID()
        XCTAssertNotNil(id)

        await repo.endSession()
        let idAfter = await repo.getCurrentSessionID()
        XCTAssertNil(idAfter)

        await repo.deleteSession(sessionID: handle.sessionID)
    }

    // MARK: - Load for nonexistent session

    func testLoadTranscriptForNonexistentSession() async {
        let transcript = await repo.loadTranscript(sessionID: "nonexistent_xyz")
        XCTAssertTrue(transcript.isEmpty)
    }

    func testLoadNotesForNonexistentSession() async {
        let notes = await repo.loadNotes(sessionID: "nonexistent_xyz")
        XCTAssertNil(notes)
    }

    // MARK: - Ask Lore chat persistence (#60)

    func testChatExchangesAppendAndLoad() async {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID

        await repo.appendChatExchange(
            sessionID: sessionID,
            exchange: ChatExchange(question: "Summarise so far", answer: "You discussed the pilot.")
        )
        await repo.appendChatExchange(
            sessionID: sessionID,
            exchange: ChatExchange(question: "Any action items?", answer: "Define baseline metrics.")
        )

        let chat = await repo.loadChat(sessionID: sessionID)
        XCTAssertEqual(chat.count, 2)
        XCTAssertEqual(chat[0].question, "Summarise so far")
        XCTAssertEqual(chat[0].answer, "You discussed the pilot.")
        XCTAssertEqual(chat[1].question, "Any action items?")

        await repo.deleteSession(sessionID: sessionID)
    }

    /// Legacy sessions have no chat.json — loadChat must return empty,
    /// never error.
    func testLoadChatMissingFileReturnsEmpty() async {
        let chat = await repo.loadChat(sessionID: "session_without_chat")
        XCTAssertTrue(chat.isEmpty)
    }

    /// A chat.json that exists but fails to decode must never be rebuilt
    /// over: append moves it aside to chat.json.corrupt (prior bytes
    /// preserved) and starts fresh with the new exchange.
    func testAppendChatExchangePreservesCorruptFileAside() async throws {
        let handle = await repo.startSession()
        let sessionID = handle.sessionID

        let sessionDir = repo.sessionsDirectoryURL
            .appendingPathComponent(sessionID, isDirectory: true)
        let chatURL = sessionDir.appendingPathComponent("chat.json")
        let corruptBytes = Data("{not json".utf8)
        try corruptBytes.write(to: chatURL)

        await repo.appendChatExchange(
            sessionID: sessionID,
            exchange: ChatExchange(question: "Still there?", answer: "Yes.")
        )

        // Prior bytes preserved aside; new exchange saved cleanly.
        let asideURL = sessionDir.appendingPathComponent("chat.json.corrupt")
        XCTAssertEqual(try Data(contentsOf: asideURL), corruptBytes)
        let chat = await repo.loadChat(sessionID: sessionID)
        XCTAssertEqual(chat.count, 1)
        XCTAssertEqual(chat[0].question, "Still there?")

        // Second corruption gets a unique aside name — the first aside
        // must survive untouched.
        let corruptBytes2 = Data("[broken again".utf8)
        try corruptBytes2.write(to: chatURL)
        await repo.appendChatExchange(
            sessionID: sessionID,
            exchange: ChatExchange(question: "Again?", answer: "Still yes.")
        )

        let asideURL2 = sessionDir.appendingPathComponent("chat.json.corrupt.1")
        XCTAssertEqual(try Data(contentsOf: asideURL), corruptBytes)
        XCTAssertEqual(try Data(contentsOf: asideURL2), corruptBytes2)
        let chatAfter = await repo.loadChat(sessionID: sessionID)
        XCTAssertEqual(chatAfter.count, 1)
        XCTAssertEqual(chatAfter[0].question, "Again?")

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - SessionRecord encoding roundtrip

    func testSessionRecordRoundTrip() throws {
        let record = SessionRecord(
            speaker: .you,
            text: "Hello there",
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            refinedText: "Hello there."
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionRecord.self, from: data)

        XCTAssertEqual(decoded.speaker, .you)
        XCTAssertEqual(decoded.text, "Hello there")
        XCTAssertEqual(decoded.refinedText, "Hello there.")
    }

    /// Records written by the retired suggestion pipeline carry extra keys
    /// (suggestions, kbHits, suggestionDecision, surfacedSuggestionText,
    /// conversationStateSummary) — they must still decode.
    func testSessionRecordWithRetiredSuggestionKeysDecodes() throws {
        let json = """
        {"speaker":"you","text":"Hello","timestamp":"2024-01-01T00:00:00Z",\
        "suggestions":["Try asking about X"],"kbHits":["doc.md"],\
        "surfacedSuggestionText":"Try asking about X",\
        "conversationStateSummary":"Intro chat"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionRecord.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.speaker, .you)
        XCTAssertEqual(decoded.text, "Hello")
        XCTAssertNil(decoded.refinedText)
    }

    // MARK: - Unviewed marker (MREV-39, additive field)

    /// A session.json written before the `unviewed` field existed must still
    /// decode, with `unviewed == nil`.
    func testSessionMetadataWithoutUnviewedFieldDecodes() async throws {
        let sessionID = "session_pre_unviewed"
        let sessionsDir = rootDir.appendingPathComponent("sessions", isDirectory: true)
        let sessionDir = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Legacy-shaped session.json: no "unviewed" key.
        let json = """
        {
          "id": "\(sessionID)",
          "startedAt": "2026-01-15T10:00:00Z",
          "endedAt": "2026-01-15T10:30:00Z",
          "title": "Old Meeting",
          "utteranceCount": 12,
          "hasNotes": false
        }
        """
        try json.write(
            to: sessionDir.appendingPathComponent("session.json"),
            atomically: true,
            encoding: .utf8
        )

        let sessions = await repo.listSessions()
        let found = sessions.first(where: { $0.id == sessionID })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "Old Meeting")
        XCTAssertEqual(found?.utteranceCount, 12)
        XCTAssertNil(found?.unviewed)

        await repo.deleteSession(sessionID: sessionID)
    }

    func testMarkSessionUnviewedAndViewedRoundTrip() async {
        let sessionID = "session_fresh_marker"
        await repo.seedSession(
            id: sessionID,
            records: [SessionRecord(speaker: .you, text: "Hi", timestamp: Date())],
            startedAt: Date()
        )

        await repo.markSessionUnviewed(sessionID: sessionID)
        var found = await repo.listSessions().first(where: { $0.id == sessionID })
        XCTAssertEqual(found?.unviewed, true)

        await repo.markSessionViewed(sessionID: sessionID)
        found = await repo.listSessions().first(where: { $0.id == sessionID })
        XCTAssertNil(found?.unviewed)

        // Other metadata survives the marker round trip.
        XCTAssertEqual(found?.utteranceCount, 1)

        await repo.deleteSession(sessionID: sessionID)
    }

    // MARK: - Imported audio retained for retry (#43)

    /// The audio copied into an imported session at kickoff must be
    /// retrievable via `audioFileURL(for:)` — it is the retry source after
    /// a failed import.
    func testCopiedImportAudioIsRetrievable() async {
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

        let source = rootDir.appendingPathComponent("source.m4a")
        try? Data("fake audio".utf8).write(to: source)
        await repo.copyAudioFileToSession(sessionID: sessionID, sourceURL: source)

        let audioURL = await repo.audioFileURL(for: sessionID)
        XCTAssertEqual(audioURL?.lastPathComponent, "imported.m4a")

        // Re-copying from the session's own file (the retry path) is a no-op
        // that leaves the audio in place.
        await repo.copyAudioFileToSession(sessionID: sessionID, sourceURL: audioURL!)
        let stillThere = await repo.audioFileURL(for: sessionID)
        XCTAssertEqual(stillThere?.lastPathComponent, "imported.m4a")

        await repo.deleteSession(sessionID: sessionID)
    }
}
