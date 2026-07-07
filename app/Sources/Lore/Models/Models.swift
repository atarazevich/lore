import Foundation

// MARK: - Session Record

/// Codable record for JSONL session persistence.
/// Older files may carry retired suggestion-pipeline keys (`suggestions`,
/// `kbHits`, `suggestionDecision`, `surfacedSuggestionText`,
/// `conversationStateSummary`); JSONDecoder skips unknown keys, so they
/// decode unchanged.
struct SessionRecord: Codable {
    let speaker: Speaker
    let text: String
    let timestamp: Date
    let refinedText: String?

    init(
        speaker: Speaker,
        text: String,
        timestamp: Date,
        refinedText: String? = nil
    ) {
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.refinedText = refinedText
    }

    func withRefinedText(_ text: String?) -> SessionRecord {
        SessionRecord(
            speaker: speaker, text: self.text, timestamp: timestamp,
            refinedText: text
        )
    }
}

// MARK: - Meeting Templates & Enhanced Notes

struct MeetingTemplate: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var icon: String
    var systemPrompt: String
    var isBuiltIn: Bool
}

struct TemplateSnapshot: Codable, Sendable {
    let id: UUID
    let name: String
    let icon: String
    let systemPrompt: String
}

struct EnhancedNotes: Codable, Sendable {
    let template: TemplateSnapshot
    let generatedAt: Date
    let markdown: String
}

struct SessionIndex: Identifiable, Codable, Sendable {
    let id: String
    let startedAt: Date
    var endedAt: Date?
    var templateSnapshot: TemplateSnapshot?
    var title: String?
    var utteranceCount: Int
    var hasNotes: Bool
    /// BCP 47 language/locale used for transcription (e.g. "en-US", "fr-FR").
    var language: String?
    /// The detected meeting application name (e.g. "Zoom", "Microsoft Teams").
    var meetingApp: String?
    /// The ASR engine used for transcription (e.g. "parakeetV2").
    var engine: String?
    /// User-assigned tags for session organization.
    var tags: [String]?
    /// How the session was created (nil for live sessions, `importedSource`
    /// for imported audio).
    var source: String?
    /// Fresh-meeting marker (MREV-39): set when batch processing / import is
    /// kicked off, cleared when the user views the processed meeting.
    /// Optional + defaulted so legacy indexes decode unchanged.
    var unviewed: Bool? = nil

    /// `source` value for sessions created via audio import (#43).
    /// Live/legacy sessions carry nil.
    static let importedSource = "imported"
}

struct SessionSidecar: Codable, Sendable {
    let index: SessionIndex
    var notes: EnhancedNotes?
}

// MARK: - Ask Lore chat (#60)

/// One completed Ask Lore exchange, persisted per session as `chat.json`.
/// Additive artifact (like `unviewed`): legacy sessions simply have no file.
/// Failure bubbles are never persisted.
struct ChatExchange: Codable, Sendable, Equatable {
    let question: String
    let answer: String
}

extension SessionIndex {
    /// Localized "Weekday HH:MM" derived from the start time — the default
    /// meeting name for new recordings (#58). Output matches the DateFormatter
    /// "EEEjmm" template per locale (e.g. "Thu 3:01 PM" / "чт 15:01") — see
    /// testDefaultTitleStyleMatchesTemplateAcrossLocales.
    static func defaultTitle(startedAt: Date) -> String {
        startedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Stored title, or the derived default when none is stored. Legacy
    /// sessions with nil titles render the derived name too — a display-only
    /// fallback; stored data is never migrated (#58).
    var displayTitle: String {
        title ?? Self.defaultTitle(startedAt: startedAt)
    }
}
