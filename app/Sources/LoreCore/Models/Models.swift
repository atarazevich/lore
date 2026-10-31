import Foundation
import LoreFormat

// MARK: - Meeting Templates & Enhanced Notes

public struct MeetingTemplate: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var icon: String
    var systemPrompt: String
    public var isBuiltIn: Bool

    public init(id: UUID, name: String, icon: String, systemPrompt: String, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.icon = icon
        self.systemPrompt = systemPrompt
        self.isBuiltIn = isBuiltIn
    }
}

public struct TemplateSnapshot: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    public let icon: String
    let systemPrompt: String
}

public struct EnhancedNotes: Codable, Sendable {
    let template: TemplateSnapshot
    let generatedAt: Date
    public let markdown: String
}

public struct SessionIndex: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let startedAt: Date
    public var endedAt: Date?
    public var templateSnapshot: TemplateSnapshot?
    public var title: String?
    public var utteranceCount: Int
    public var hasNotes: Bool
    /// BCP 47 language/locale used for transcription (e.g. "en-US", "fr-FR").
    var language: String?
    /// The detected meeting application name (e.g. "Zoom", "Microsoft Teams").
    var meetingApp: String?
    /// The ASR engine used for transcription (e.g. "parakeetV2").
    var engine: String?
    /// User-assigned tags for session organization.
    public var tags: [String]?
    /// How the session was created (nil for live sessions, `importedSource`
    /// for imported audio, `PhoneNotes.source` for a note from the iPhone).
    public var source: String?
    /// Fresh-meeting marker (MREV-39): set when batch processing / import is
    /// kicked off, cleared when the user views the processed meeting.
    /// Optional + defaulted so legacy indexes decode unchanged.
    public var unviewed: Bool? = nil
    /// On-device enrichment summary (#107): 1–2 factual sentences generated
    /// by Apple Foundation Models. Doubles as the enriched marker — nil means
    /// "not yet enriched" and the launch sweep will pick the session up.
    public var summary: String? = nil
    /// Persisted no-speech verdict (#166): a completed transcription pass
    /// over this session's audio produced no text, so nothing changes by
    /// running again — the sweep and open-summons skip it instead of
    /// re-transcribing silence every launch. Cleared whenever a final
    /// transcript lands. Optional — absent in older files.
    public var noSpeech: Bool? = nil

    /// Derived at list time (#109), never persisted (excluded from
    /// CodingKeys): whether `transcript.final.jsonl` exists — a whole
    /// (rebuilt-from-audio) transcript vs the chunked live one. The launch
    /// sweep (#166) reads it to tell a completed-but-uncleaned batch stash
    /// from an interrupted one. The iPhone app reads it to tell a
    /// transcribed note from one still waiting for its pass.
    public internal(set) var hasFinalTranscript = false

    /// `source` value for sessions created via audio import (#43).
    /// Live/legacy sessions carry nil.
    static let importedSource = "imported"

    /// Everything except the derived transcript-state flag (#109) — it
    /// describes the filesystem, not the session, and must never be persisted
    /// (session.json or legacy sidecars).
    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, templateSnapshot, title, utteranceCount,
             hasNotes, language, meetingApp, engine, tags, source, unviewed,
             summary, noSpeech
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
public struct ChatExchange: Codable, Sendable, Equatable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

extension SessionIndex {
    /// Localized "Weekday HH:MM" derived from the start time — the default
    /// meeting name for new recordings (#58). Output matches the DateFormatter
    /// "EEEjmm" template per locale (e.g. "Thu 3:01 PM" / "чт 15:01") — see
    /// testDefaultTitleStyleMatchesTemplateAcrossLocales.
    public static func defaultTitle(startedAt: Date) -> String {
        MeetingInfo.defaultTitle(startedAt: startedAt)
    }

    /// Whether a stored title is still a default one (#269): the default for
    /// any minute within two of the start. The title and the stored start
    /// were read from different clocks before, a minute apart at times.
    public static func isDefaultTitle(_ title: String, startedAt: Date) -> Bool {
        (-2...2).contains { title == defaultTitle(startedAt: startedAt.addingTimeInterval(Double($0) * 60)) }
    }

    /// Stored title, or the derived default when none is stored. Legacy
    /// sessions with nil titles render the derived name too — a display-only
    /// fallback; stored data is never migrated (#58).
    public var displayTitle: String {
        title ?? Self.defaultTitle(startedAt: startedAt)
    }
}
