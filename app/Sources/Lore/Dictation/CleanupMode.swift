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

    static let punctuationOnlyPrompt = "You are processing a voice dictation. Keep the wording exactly as spoken \u{2014} do not remove, add, replace, or reorder any words. Only add punctuation, fix capitalization, and break the text into paragraphs at natural pauses. Preserve fillers and repetitions as spoken. Output only the punctuated text."

    static let formalTonePrompt = "You are processing a voice dictation into formal written text. Remove fillers, false starts, and repetitions, then rewrite the content in a formal, professional tone. Preserve the meaning and every fact, name, number, and technical term exactly. Keep the same language as the input. Output only the rewritten text."

    static let bulletPointsPrompt = "You are processing a voice dictation into a bullet-point list. Remove fillers, false starts, and repetitions, then condense the content into concise bullet points \u{2014} one bullet per distinct idea, preserving every fact, name, number, and technical term. Keep the same language as the input. Format each bullet as a line starting with \"- \". Output only the list."

    /// Suffix appended to a cleanup prompt to also translate the result.
    /// Defaults to English so the pre-paste chord (Fn+T), translate-by-default,
    /// and the post-paste T upgrade all keep their translate-to-English behavior;
    /// the history row's language popover passes an explicit target (DIC-36).
    static func translateSuffix(to language: TranslationLanguage = .english) -> String {
        "\n\nAlso translate the result into \(language.displayName). Output only the translated text."
    }

    /// Resolve the prompt for a given preset, with optional custom text.
    static func prompt(for preset: CleanupPreset, customPrompt: String = "") -> String {
        switch preset {
        case .clean: cleanPrompt
        case .concise: concisePrompt
        case .custom: customPrompt
        }
    }

}

// MARK: - Retroactive Cleanup Methods (history row popover, DIC-35)

/// Cleanup methods offered by the history row's "Clean up \u{2726}" popover.
/// `standard` maps to the user's active cleanup preset prompt (the same prompt
/// used by defaults, chords, and upgrade keys); the other three carry fixed
/// prompts.
///
/// The raw value is the stable key persisted in history JSON
/// (`DictationHistoryEntry.cleanupMethodName`) \u{2014} never rename cases' raw
/// values. Display text lives in `displayName`; popover subtitle/glyph
/// presentation lives in the view layer.
enum CleanupMethod: String, CaseIterable, Identifiable {
    case standard
    case punctuationOnly = "punctuation-only"
    case formalTone = "formal-tone"
    case bulletPoints = "bullet-points"

    var id: String { rawValue }

    /// Stable persisted key (history JSON).
    var key: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .punctuationOnly: "Punctuation only"
        case .formalTone: "Formal tone"
        case .bulletPoints: "Bullet points"
        }
    }

    /// Resolve the cleanup prompt for this method.
    func prompt(activePresetPrompt: String) -> String {
        switch self {
        case .standard: activePresetPrompt
        case .punctuationOnly: CleanupMode.punctuationOnlyPrompt
        case .formalTone: CleanupMode.formalTonePrompt
        case .bulletPoints: CleanupMode.bulletPointsPrompt
        }
    }
}

// MARK: - Translation Languages (history row popover, DIC-36)

/// Target languages offered by the history row's "Translate" popover.
/// The raw value is the stable key persisted in history JSON
/// (`DictationHistoryEntry.translatedToLanguage`) \u{2014} never rename cases'
/// raw values.
enum TranslationLanguage: String, CaseIterable, Identifiable {
    case english
    case russian
    case spanish
    case german
    case french
    case portuguese

    var id: String { rawValue }

    /// Stable persisted key (history JSON).
    var key: String { rawValue }

    var displayName: String { rawValue.capitalized }
}

