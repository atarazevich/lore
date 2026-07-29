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

    /// Refined text when the batch pass produced one, else the live text.
    var displayText: String { refinedText ?? text }

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
    /// On-device enrichment summary (#107): 1–2 factual sentences generated
    /// by Apple Foundation Models. Doubles as the enriched marker — nil means
    /// "not yet enriched" and the launch sweep will pick the session up.
    var summary: String? = nil

    /// Derived at list time (#109), never persisted (excluded from
    /// CodingKeys): whether `transcript.final.jsonl` exists — a whole
    /// (rebuilt-from-audio) transcript vs the chunked live one.
    var hasFinalTranscript = false
    /// Derived at list time (#109), never persisted: whether audio to rebuild
    /// from is findable (per-track stash, session audio copy, or the merged
    /// m4a export in the notes folder). Only derived for chunked sessions.
    var hasRebuildAudio = false

    /// `source` value for sessions created via audio import (#43).
    /// Live/legacy sessions carry nil.
    static let importedSource = "imported"

    /// Everything except the derived transcript-state flags (#109) — those
    /// describe the filesystem, not the session, and must never be persisted
    /// (session.json or legacy sidecars).
    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, templateSnapshot, title, utteranceCount,
             hasNotes, language, meetingApp, engine, tags, source, unviewed,
             summary
    }
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
