import XCTest
@testable import LoreKit

/// Read Aloud (#105): chunking, language detection → voice resolution, input
/// validation, client request shape / error mapping, speed ladder, settings
/// persistence.
final class ReadAloudTests: XCTestCase {

    // MARK: - Chunking

    func testShortTextIsSingleChunk() {
        XCTAssertEqual(ReadAloudController.chunk("Привет, мир."), ["Привет, мир."])
    }

    func testEmptyAndWhitespaceYieldNoChunks() {
        XCTAssertEqual(ReadAloudController.chunk(""), [])
        XCTAssertEqual(ReadAloudController.chunk("  \n\t "), [])
    }

    private static let russianSentence =
        "Это предложение среднего размера, написанное для проверки логики нарезки текста."

    private static var longRussianText: String {
        Array(repeating: russianSentence, count: 100).joined(separator: " ")
    }

    func testFirstChunkIsSmallForFastStart() {
        let chunks = ReadAloudController.chunk(Self.longRussianText)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks[0].count, 300)
    }

    func testLaterChunksRespectTarget() {
        let chunks = ReadAloudController.chunk(Self.longRussianText)
        for chunk in chunks.dropFirst() {
            XCTAssertLessThanOrEqual(chunk.count, 1500)
        }
    }

    func testChunksEndAtSentenceBoundaries() {
        let chunks = ReadAloudController.chunk(Self.longRussianText)
        // Every sentence in the fixture ends with a period, so every chunk
        // except possibly the last must end on one.
        for chunk in chunks.dropLast() {
            XCTAssertEqual(chunk.last, ".", "chunk broke mid-sentence: …\(chunk.suffix(40))")
        }
    }

    func testChunksPreserveEveryWord() {
        let original = Self.longRussianText
            .split(whereSeparator: \.isWhitespace)
        let rejoined = ReadAloudController.chunk(Self.longRussianText)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(original, rejoined)
    }

    func testOversizedSentenceFallsBackToWordCuts() {
        // 600 words, no sentence terminator anywhere.
        let text = Array(repeating: "слово", count: 600).joined(separator: " ")
        let chunks = ReadAloudController.chunk(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks[0].count, 300)
        for chunk in chunks.dropFirst() {
            XCTAssertLessThanOrEqual(chunk.count, 1500)
        }
        // Words never split.
        let rejoined = chunks.joined(separator: " ").split(separator: " ")
        XCTAssertEqual(rejoined.count, 600)
        XCTAssertTrue(rejoined.allSatisfy { $0 == "слово" })
    }

    func testUnbrokenRunIsHardCut() {
        let text = String(repeating: "ж", count: 700)
        let chunks = ReadAloudController.chunk(text)
        XCTAssertEqual(chunks.map(\.count), [300, 400])
    }

    // MARK: - Language detection → voice resolution

    private static let russianParagraph = """
        Сегодня мы обсуждали планы на следующий квартал. Основное внимание \
        уделили разработке нового продукта и найму инженеров.
        """
    private static let englishParagraph = """
        Today we discussed the plans for the next quarter. The main focus \
        was product development and engineering hiring.
        """

    func testDetectsRussianParagraph() {
        XCTAssertEqual(ReadAloudController.detectLanguage(Self.russianParagraph), .russian)
    }

    func testDetectsEnglishParagraph() {
        XCTAssertEqual(ReadAloudController.detectLanguage(Self.englishParagraph), .english)
    }

    func testMixedTextFollowsDominantLanguage() {
        let mostlyRussian = Self.russianParagraph + " deadline scope review"
        XCTAssertEqual(ReadAloudController.detectLanguage(mostlyRussian), .russian)
        let mostlyEnglish = Self.englishParagraph + " дедлайн"
        XCTAssertEqual(ReadAloudController.detectLanguage(mostlyEnglish), .english)
    }

    func testOtherLanguagesCarryTheirCode() {
        let german = "Heute haben wir die Pläne für das nächste Quartal besprochen."
        XCTAssertEqual(ReadAloudController.detectLanguage(german), .other("de"))
        XCTAssertEqual(ReadAloudController.languageDisplayName("de"), "German")
    }

    private static let agrippina = ReadAloudVoiceChoice(
        engine: .speechify, id: "agrippina", name: "Agrippina"
    )
    private static let henry = ReadAloudVoiceChoice(
        engine: .speechify, id: "henry", name: "Henry"
    )

    func testResolveVoiceRussianSpeechify() {
        let voice = ReadAloudController.resolveVoice(
            for: Self.russianParagraph, mode: .perLanguage,
            ru: Self.agrippina, en: Self.henry,
            other: .systemAuto, single: ReadAloudVoices.defaultSingle,
            hasSpeechifyKey: true
        )
        XCTAssertEqual(voice.engine, .speechify)
        XCTAssertEqual(voice.voiceID, "agrippina")
        XCTAssertEqual(voice.displayName, "Agrippina")
        XCTAssertEqual(voice.initial, "A")
        XCTAssertEqual(voice.model, "simba-multilingual")
        XCTAssertEqual(voice.languageParam, "ru-RU")
        XCTAssertEqual(voice.languageName, "Russian")
    }

    func testResolveVoiceEnglishSpeechify() {
        let voice = ReadAloudController.resolveVoice(
            for: Self.englishParagraph, mode: .perLanguage,
            ru: Self.agrippina, en: Self.henry,
            other: .systemAuto, single: ReadAloudVoices.defaultSingle,
            hasSpeechifyKey: true
        )
        XCTAssertEqual(voice.engine, .speechify)
        XCTAssertEqual(voice.voiceID, "henry")
        XCTAssertEqual(voice.model, "simba-english")
        XCTAssertNil(voice.languageParam)
        XCTAssertEqual(voice.languageName, "English")
    }

    func testResolveVoiceOtherLanguageSystemAuto() {
        let german = "Heute haben wir die Pläne für das nächste Quartal besprochen."
        let voice = ReadAloudController.resolveVoice(
            for: german, mode: .perLanguage,
            ru: Self.agrippina, en: Self.henry,
            other: .systemAuto, single: ReadAloudVoices.defaultSingle,
            hasSpeechifyKey: true
        )
        XCTAssertEqual(voice.engine, .system)
        XCTAssertEqual(voice.voiceID, ReadAloudVoiceChoice.systemAutoID)
        XCTAssertEqual(voice.model, "system")
        XCTAssertEqual(voice.languageParam, "de")
        XCTAssertEqual(voice.languageName, "German")
    }

    /// Free-first tiering: a Speechify choice without a key degrades to the
    /// system auto voice — never a hard requirement, never a crash.
    func testResolveVoiceWithoutKeyFallsBackToSystem() {
        let voice = ReadAloudController.resolveVoice(
            for: Self.russianParagraph, mode: .perLanguage,
            ru: Self.agrippina, en: Self.henry,
            other: .systemAuto, single: ReadAloudVoices.defaultSingle,
            hasSpeechifyKey: false
        )
        XCTAssertEqual(voice.engine, .system)
        XCTAssertEqual(voice.voiceID, ReadAloudVoiceChoice.systemAutoID)
        XCTAssertEqual(voice.languageParam, "ru")
    }

    /// Single-voice mode always uses the multilingual model — even for
    /// English text, where per-language mode would pick simba-english.
    func testSingleVoiceModeForcesMultilingualModel() {
        let voice = ReadAloudController.resolveVoice(
            for: Self.englishParagraph, mode: .singleVoice,
            ru: .systemAuto, en: .systemAuto,
            other: .systemAuto, single: ReadAloudVoices.defaultSingle,
            hasSpeechifyKey: true
        )
        XCTAssertEqual(voice.engine, .speechify)
        XCTAssertEqual(voice.voiceID, "leonid")
        XCTAssertEqual(voice.model, "simba-multilingual")
        XCTAssertNil(voice.languageParam)
    }

    // MARK: - Voice choice persistence format

    func testVoiceChoiceRawValueRoundTrip() {
        let system = ReadAloudVoiceChoice(
            engine: .system, id: "com.apple.voice.compact.ru-RU.Milena", name: "Milena"
        )
        XCTAssertEqual(ReadAloudVoiceChoice(rawValue: system.rawValue), system)
        let speechify = ReadAloudVoiceChoice(engine: .speechify, id: "leonid", name: "Leonid")
        XCTAssertEqual(speechify.rawValue, "speechify|leonid|Leonid")
        XCTAssertEqual(ReadAloudVoiceChoice(rawValue: speechify.rawValue), speechify)
        XCTAssertNil(ReadAloudVoiceChoice(rawValue: "garbage"))
        XCTAssertNil(ReadAloudVoiceChoice(rawValue: "unknownengine|x|Y"))
    }

    func testAvatarInitials() {
        XCTAssertEqual(ReadAloudVoices.avatarInitial(for: Self.agrippina), "A")
        XCTAssertEqual(ReadAloudVoices.avatarInitial(for: Self.henry), "H")
        XCTAssertEqual(
            ReadAloudVoices.avatarInitial(
                for: ReadAloudVoiceChoice(engine: .system, id: "x", name: "milena")
            ),
            "M"
        )
    }

    // MARK: - Capture resolution (clipboard fallback, #106)

    func testSelectionWinsOverClipboard() throws {
        let captured = try XCTUnwrap(
            TextInserter.resolveCapture(selection: "выделение", clipboard: "буфер")
        )
        XCTAssertEqual(captured.text, "выделение")
        XCTAssertFalse(captured.fromClipboard)
    }

    func testClipboardUsedWhenSelectionEmpty() throws {
        let fromNil = try XCTUnwrap(
            TextInserter.resolveCapture(selection: nil, clipboard: "буфер")
        )
        XCTAssertEqual(fromNil.text, "буфер")
        XCTAssertTrue(fromNil.fromClipboard)
        // Whitespace-only selection counts as absent, same as nil.
        let fromWhitespace = try XCTUnwrap(
            TextInserter.resolveCapture(selection: "  \n ", clipboard: "буфер")
        )
        XCTAssertEqual(fromWhitespace.text, "буфер")
        XCTAssertTrue(fromWhitespace.fromClipboard)
    }

    func testNothingCapturedWhenBothEmpty() {
        XCTAssertNil(TextInserter.resolveCapture(selection: nil, clipboard: nil))
        XCTAssertNil(TextInserter.resolveCapture(selection: " ", clipboard: "\n\t"))
        XCTAssertEqual(
            ReadAloudController.validationNotice(for: .unreadable), "No readable text"
        )
    }

    /// A symbols-only selection must not block a readable clipboard: the
    /// unreadable verdict retries against the clipboard. Over-limit never
    /// falls back — that text was deliberately selected.
    func testUnreadableSelectionFallsBackToClipboard() {
        let retried = ReadAloudController.resolveValidation(
            captured: (text: "*** —…", fromClipboard: false),
            clipboard: "буфер", limit: 100
        )
        XCTAssertEqual(retried.validation, .ok("буфер"))
        XCTAssertTrue(retried.fromClipboard)

        // Already clipboard-sourced — no second retry, the notice stands.
        let clipboardUnreadable = ReadAloudController.resolveValidation(
            captured: (text: "***", fromClipboard: true),
            clipboard: "***", limit: 100
        )
        XCTAssertEqual(clipboardUnreadable.validation, .unreadable)

        // Over-limit selection is an error, not a fallback.
        let overLimit = ReadAloudController.resolveValidation(
            captured: (text: String(repeating: "a", count: 101), fromClipboard: false),
            clipboard: "буфер", limit: 100
        )
        XCTAssertEqual(overLimit.validation, .overLimit(count: 101, limit: 100))
        XCTAssertFalse(overLimit.fromClipboard)
    }

    // MARK: - Input validation

    func testValidateTrimsAndAccepts() {
        XCTAssertEqual(
            ReadAloudController.validate("  Привет \n", limit: 100),
            .ok("Привет")
        )
    }

    func testValidateNilIsUnreadable() {
        XCTAssertEqual(ReadAloudController.validate(nil, limit: 100), .unreadable)
    }

    func testValidateRejectsSymbolsOnly() {
        XCTAssertEqual(
            ReadAloudController.validate("→ …—! *** __ ", limit: 100),
            .unreadable
        )
    }

    func testValidateOverLimitCarriesCounts() {
        XCTAssertEqual(
            ReadAloudController.validate(String(repeating: "a", count: 21), limit: 20),
            .overLimit(count: 21, limit: 20)
        )
    }

    func testValidateAtLimitPasses() {
        let text = String(repeating: "a", count: 20)
        XCTAssertEqual(ReadAloudController.validate(text, limit: 20), .ok(text))
    }

    func testOverLimitNoticeGroupsWithEnglishLocale() {
        let overLimit = ReadAloudController.validationNotice(
            for: .overLimit(count: 25_340, limit: 20_000)
        )
        XCTAssertEqual(overLimit, "Text too long (25,340 characters)")
    }

    // MARK: - Error mapping / transience

    func testTransientSpeechifyErrors() {
        XCTAssertTrue(SpeechifyClient.isTransient(SpeechifyClient.SpeechifyError.apiError(429)))
        XCTAssertTrue(SpeechifyClient.isTransient(SpeechifyClient.SpeechifyError.apiError(500)))
        XCTAssertTrue(SpeechifyClient.isTransient(SpeechifyClient.SpeechifyError.apiError(503)))
        XCTAssertFalse(SpeechifyClient.isTransient(SpeechifyClient.SpeechifyError.apiError(400)))
        XCTAssertFalse(SpeechifyClient.isTransient(SpeechifyClient.SpeechifyError.apiError(401)))
        XCTAssertFalse(SpeechifyClient.isTransient(SpeechifyClient.SpeechifyError.apiError(402)))
        XCTAssertTrue(SpeechifyClient.isTransient(URLError(.timedOut)))
        XCTAssertTrue(SpeechifyClient.isTransient(URLError(.networkConnectionLost)))
        XCTAssertFalse(SpeechifyClient.isTransient(URLError(.cancelled)))
        struct Dummy: Error {}
        XCTAssertFalse(SpeechifyClient.isTransient(Dummy()))
    }

    func testHttpStatusExtraction() {
        XCTAssertEqual(
            SpeechifyClient.httpStatus(from: SpeechifyClient.SpeechifyError.apiError(401)), 401
        )
        XCTAssertNil(SpeechifyClient.httpStatus(from: URLError(.timedOut)))
    }

    func testFailureNotices() {
        XCTAssertTrue(
            ReadAloudController.failureNotice(
                for: SpeechifyClient.SpeechifyError.apiError(401)
            ).contains("401")
        )
        XCTAssertTrue(
            ReadAloudController.failureNotice(for: URLError(.timedOut))
                .localizedCaseInsensitiveContains("connection")
        )
    }

    // MARK: - Client request shape (StubURLProtocol)

    func testSynthesizeSendsExpectedRequestShape() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let mp3 = Data([0xFF, 0xF3, 0x00, 0x01])
        StubURLProtocol.responder = { _ in (200, mp3) }

        let client = SpeechifyClient(session: StubURLProtocol.session())
        let url = try await client.synthesize(
            text: "Привет.", voice: "leonid", model: "simba-multilingual",
            language: "ru-RU", apiKey: "TESTKEY"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), mp3)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url, SpeechifyClient.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TESTKEY")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "audio/mpeg")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["input"] as? String, "Привет.")
        XCTAssertEqual(json["voice_id"] as? String, "leonid")
        XCTAssertEqual(json["model"] as? String, "simba-multilingual")
        XCTAssertEqual(json["language"] as? String, "ru-RU")
    }

    func testSynthesizeOmitsLanguageWhenNil() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.responder = { _ in (200, Data([0x00])) }

        let client = SpeechifyClient(session: StubURLProtocol.session())
        let url = try await client.synthesize(
            text: "Hello.", voice: "henry", model: "simba-english",
            language: nil, apiKey: "TESTKEY"
        )
        try? FileManager.default.removeItem(at: url)
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "simba-english")
        XCTAssertNil(json["language"])
    }

    func testSynthesizeNon2xxThrowsMappedError() async {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.responder = { _ in
            (401, Data(#"{"error":{"code":"unauthorized"}}"#.utf8))
        }

        let client = SpeechifyClient(session: StubURLProtocol.session())
        do {
            _ = try await client.synthesize(
                text: "x", voice: "leonid", model: "simba-multilingual",
                language: nil, apiKey: "BAD"
            )
            XCTFail("expected apiError(401)")
        } catch {
            XCTAssertEqual(error as? SpeechifyClient.SpeechifyError, .apiError(401))
        }
    }

    // MARK: - Speed ladder & labels

    func testNextSpeedCyclesAndWraps() {
        XCTAssertEqual(ReadAloudController.nextSpeed(after: 1.0), 1.25)
        XCTAssertEqual(ReadAloudController.nextSpeed(after: 0.5), 0.75)
        XCTAssertEqual(ReadAloudController.nextSpeed(after: 3.0), 0.5)
    }

    func testNextSpeedFromUnknownValueResets() {
        XCTAssertEqual(ReadAloudController.nextSpeed(after: 1.37), 1.0)
    }

    func testSpeedLabels() {
        XCTAssertEqual(ReadAloudController.speedLabel(1.0), "1×")
        XCTAssertEqual(ReadAloudController.speedLabel(0.75), "0.75×")
        XCTAssertEqual(ReadAloudController.speedLabel(3.0), "3×")
    }

    func testTimeAndEstimateLabels() {
        XCTAssertEqual(ReadAloudController.timeLabel(0), "0:00")
        XCTAssertEqual(ReadAloudController.timeLabel(65.4), "1:05")
        // 1700 chars ≈ 100 s at 1x, halved at 2x.
        XCTAssertEqual(ReadAloudController.estimateLabel(chars: 1700, rate: 1.0), "~1:40")
        XCTAssertEqual(ReadAloudController.estimateLabel(chars: 1700, rate: 2.0), "~0:50")
    }

    // MARK: - Snippets

    func testSnippetTakesFirstLineAndCapsLength() {
        XCTAssertEqual(
            ReadAloudController.snippet(of: "  Первая строка.\nВторая строка."),
            "Первая строка."
        )
        XCTAssertEqual(
            ReadAloudController.snippet(of: String(repeating: "а", count: 200)).count, 80
        )
    }

    // MARK: - Settings persistence (#105)

    @MainActor
    private func makeStore(
        suite: UserDefaults? = nil, secretStore: AppSecretStore = .ephemeral
    ) -> SettingsStore {
        let storage = SettingsStorage(
            defaults: suite ?? UserDefaults(suiteName: "com.lore.test.\(UUID().uuidString)")!,
            secretStore: secretStore,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ReadAloudTests"),
            legacyNotesDirectories: [],
            runMigrations: false
        )
        return SettingsStore(storage: storage)
    }

    @MainActor
    func testReadAloudSettingsDefaults() {
        let store = makeStore()
        // Free-first (#105): system voices everywhere on a fresh install.
        XCTAssertEqual(store.readAloudVoiceMode, .perLanguage)
        XCTAssertEqual(store.readAloudVoiceRu, .systemAuto)
        XCTAssertEqual(store.readAloudVoiceEn, .systemAuto)
        XCTAssertEqual(store.readAloudVoiceOther, .systemAuto)
        XCTAssertEqual(store.readAloudVoiceSingle, ReadAloudVoices.defaultSingle)
        XCTAssertEqual(store.readAloudSpeed, 1.0)
        XCTAssertEqual(store.readAloudCharLimit, 20_000)
        XCTAssertFalse(store.readAloudResumeAfterDictation)
        XCTAssertEqual(store.speechifyApiKey, "")
    }

    @MainActor
    func testReadAloudSettingsPersistAcrossStores() {
        let suite = UserDefaults(suiteName: "com.lore.test.\(UUID().uuidString)")!
        let first = makeStore(suite: suite)
        let milena = ReadAloudVoiceChoice(
            engine: .system, id: "com.apple.voice.compact.ru-RU.Milena", name: "Milena"
        )
        first.readAloudVoiceMode = .singleVoice
        first.readAloudVoiceRu = milena
        first.readAloudVoiceEn = Self.henry
        first.readAloudVoiceOther = Self.agrippina
        first.readAloudVoiceSingle = Self.agrippina
        first.readAloudSpeed = 2.0
        first.readAloudCharLimit = 5000
        first.readAloudResumeAfterDictation = true

        // A second store over the same suite = relaunch.
        let second = makeStore(suite: suite)
        XCTAssertEqual(second.readAloudVoiceMode, .singleVoice)
        XCTAssertEqual(second.readAloudVoiceRu, milena)
        XCTAssertEqual(second.readAloudVoiceEn, Self.henry)
        XCTAssertEqual(second.readAloudVoiceOther, Self.agrippina)
        XCTAssertEqual(second.readAloudVoiceSingle, Self.agrippina)
        XCTAssertEqual(second.readAloudSpeed, 2.0)
        XCTAssertEqual(second.readAloudCharLimit, 5000)
        XCTAssertTrue(second.readAloudResumeAfterDictation)
    }

    @MainActor
    func testReadAloudCharLimitFlooredAt100() {
        let store = makeStore()
        store.readAloudCharLimit = 0
        XCTAssertEqual(store.readAloudCharLimit, 100)
        store.readAloudCharLimit = -5
        XCTAssertEqual(store.readAloudCharLimit, 100)
        store.readAloudCharLimit = 5000
        XCTAssertEqual(store.readAloudCharLimit, 5000)
    }

    @MainActor
    func testSpeechifyKeyGoesThroughSecretStoreOnly() {
        let suite = UserDefaults(suiteName: "com.lore.test.\(UUID().uuidString)")!
        // In-memory stand-in for the Keychain.
        final class Box: @unchecked Sendable {
            var values: [String: String] = [:]
            let lock = NSLock()
        }
        let box = Box()
        let secretStore = AppSecretStore(
            loadValue: { key in box.lock.withLock { box.values[key] } },
            saveValue: { key, value in box.lock.withLock { box.values[key] = value } }
        )

        let first = makeStore(suite: suite, secretStore: secretStore)
        first.speechifyApiKey = "sp_test_123"
        XCTAssertEqual(box.lock.withLock { box.values["speechifyApiKey"] }, "sp_test_123")

        let second = makeStore(suite: suite, secretStore: secretStore)
        XCTAssertEqual(second.speechifyApiKey, "sp_test_123")

        // Never mirrored into UserDefaults.
        XCTAssertNil(suite.string(forKey: "speechifyApiKey"))
    }
}
