import Foundation

struct CleanupMode: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var prompt: String
    var hotkey: String?

    /// Whether this mode skips the LLM cleanup and pastes raw transcription.
    var isRawPaste: Bool { prompt.isEmpty }

    init(id: UUID = UUID(), name: String, prompt: String, hotkey: String? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.hotkey = hotkey
    }

    // MARK: - Static Defaults

    static let pasteRawID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultCleanupID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let translateEnglishID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    static let pasteRaw = CleanupMode(
        id: pasteRawID,
        name: "Paste raw",
        prompt: "",
        hotkey: "1"
    )

    static let defaultCleanup = CleanupMode(
        id: defaultCleanupID,
        name: "Cleanup",
        prompt: "You are a dictation cleanup assistant. Fix grammar, punctuation, and formatting of the transcribed speech. Keep the original meaning and tone. Output only the cleaned text, nothing else.",
        hotkey: "2"
    )

    static let translateEnglish = CleanupMode(
        id: translateEnglishID,
        name: "Translate to English",
        prompt: "Translate the following transcribed speech into English. Keep the original meaning and tone. Output only the translated text, nothing else.",
        hotkey: "3"
    )

    static let defaultModes: [CleanupMode] = [pasteRaw, defaultCleanup, translateEnglish]
}

