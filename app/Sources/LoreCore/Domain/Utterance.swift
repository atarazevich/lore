import Foundation
import LoreFormat

/// The transcript's speaker, from LoreFormat (#301). Named here because
/// FluidAudio exports a `Speaker` too, and a declaration in this module wins.
typealias Speaker = LoreFormat.Speaker

// MARK: - Refinement Status

public enum RefinementStatus: String, Codable, Sendable {
    case pending, completed, failed, skipped
}

// MARK: - Utterance

public struct Utterance: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let speaker: LoreFormat.Speaker
    public let timestamp: Date
    let refinedText: String?
    let refinementStatus: RefinementStatus?

    public init(text: String, speaker: LoreFormat.Speaker, timestamp: Date = .now, refinedText: String? = nil, refinementStatus: RefinementStatus? = nil) {
        self.id = UUID()
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
        self.refinedText = refinedText
        self.refinementStatus = refinementStatus
    }

    /// The best available text: refined if available, otherwise raw.
    public var displayText: String {
        refinedText ?? text
    }

    func withRefinement(text: String?, status: RefinementStatus) -> Utterance {
        Utterance(
            id: self.id,
            text: self.text,
            speaker: self.speaker,
            timestamp: self.timestamp,
            refinedText: text,
            refinementStatus: status
        )
    }

    /// Private memberwise init that preserves an existing ID.
    private init(id: UUID, text: String, speaker: Speaker, timestamp: Date, refinedText: String?, refinementStatus: RefinementStatus?) {
        self.id = id
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
        self.refinedText = refinedText
        self.refinementStatus = refinementStatus
    }
}

