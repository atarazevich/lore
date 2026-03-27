import Foundation

// MARK: - Cleanup Preset

enum CleanupPreset: String, CaseIterable, Identifiable, Codable {
    case clean
    case concise
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clean: "Clean (default)"
        case .concise: "Concise"
        case .custom: "Custom"
        }
    }
}

// MARK: - Cleanup Mode

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

    // MARK: - Preset Prompts

    static let cleanPrompt = "You are processing a voice dictation into clean text. Rules:\n1. Remove all fillers (um, uh, like, you know, right, basically, I mean, so)\n2. Remove all repetitions and false starts\n3. Remove verbal thinking (\"let me think\", \"hold on\", \"what was I saying\")\n4. Fix grammar and punctuation\n5. Break into logical paragraphs\n6. Preserve technical terms exactly\n7. Keep the speaker's voice \u{2014} don't make it overly formal\nOutput only the cleaned text."

    static let concisePrompt = "Clean up this dictation transcript. Remove ALL filler words, false starts, repetitions, and self-corrections. Restructure run-on sentences into clear, concise ones. Preserve the speaker's intent and key points but make the text read as polished written prose. Output only the cleaned text."

    static let translateSuffix = "\n\nAlso translate the result into English. Output only the translated text."

    /// Resolve the prompt for a given preset, with optional custom text.
    static func prompt(for preset: CleanupPreset, customPrompt: String = "") -> String {
        switch preset {
        case .clean: cleanPrompt
        case .concise: concisePrompt
        case .custom: customPrompt
        }
    }

}

