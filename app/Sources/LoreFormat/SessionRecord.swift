import Foundation

// One line of a meeting transcript as it is stored, shared by the app and the
// `lore` command (#301), which reads meetings from disk with the app closed.

// MARK: - Speaker

public enum Speaker: Codable, Sendable, Hashable {
    case you
    case them
    case remote(Int)

    public var displayLabel: String {
        switch self {
        case .you: "You"
        case .them: "Them"
        case .remote(let n): "Speaker \(n)"
        }
    }

    /// True for any non-mic speaker (.them or .remote).
    public var isRemote: Bool {
        switch self {
        case .you: false
        case .them, .remote: true
        }
    }

    /// Stable key for persistence (JSONL encoding, backfill dedup).
    public var storageKey: String {
        switch self {
        case .you: "you"
        case .them: "them"
        case .remote(let n): "remote_\(n)"
        }
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "you": self = .you
        case "them": self = .them
        default:
            if raw.hasPrefix("remote_"), let n = Int(raw.dropFirst("remote_".count)) {
                self = .remote(n)
            } else {
                self = .them
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }
}

// MARK: - Session Record

/// Codable record for JSONL session persistence.
/// Older files may carry retired suggestion-pipeline keys (`suggestions`,
/// `kbHits`, `suggestionDecision`, `surfacedSuggestionText`,
/// `conversationStateSummary`); JSONDecoder skips unknown keys, so they
/// decode unchanged.
public struct SessionRecord: Codable, Equatable, Sendable {
    public let speaker: Speaker
    public let text: String
    public let timestamp: Date
    public let refinedText: String?

    public init(
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
    public var displayText: String { refinedText ?? text }

    public func withRefinedText(_ text: String?) -> SessionRecord {
        SessionRecord(
            speaker: speaker, text: self.text, timestamp: timestamp,
            refinedText: text
        )
    }
}
