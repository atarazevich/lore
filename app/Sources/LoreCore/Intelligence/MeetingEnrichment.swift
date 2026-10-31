import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A meeting's title, work/personal type, people, organizations and summary,
/// made in one call to Apple's on-device model (#107). Shared by the Mac's
/// enrichment engine and the iPhone app (#306).
public enum MeetingEnrichment {
    public enum MeetingType: String, Sendable {
        case work
        case personal
    }

    /// What one run produced, whatever made it.
    public struct Result: Sendable {
        public var title: String
        public var type: MeetingType
        public var people: [String]
        public var organizations: [String]
        public var summary: String

        public init(title: String, type: MeetingType, people: [String], organizations: [String], summary: String) {
            self.title = title
            self.type = type
            self.people = people
            self.organizations = organizations
            self.summary = summary
        }
    }

    /// macOS or iOS 26 with Apple Intelligence ready.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// nil when the on-device model is unavailable or `lines` is empty.
    public static func generate(forTranscript lines: [String]) async throws -> Result? {
        guard !lines.isEmpty else { return nil }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *), isAvailable else { return nil }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        let result = try await session.respond(to: prompt(forTranscript: lines), generating: GeneratedEnrichment.self).content
        let type: MeetingType = switch result.type {
        case .work: .work
        case .personal: .personal
        }
        return Result(
            title: result.title, type: type, people: result.people,
            organizations: result.organizations, summary: result.summary)
        #else
        return nil
        #endif
    }

    // MARK: - Prompt assembly (validated in experiments/enrichment)

    private static func prompt(forTranscript lines: [String]) -> String {
        "Transcript:\n\(clipped(lines))\n\nProduce the title, type, people, organizations, and summary."
    }

    private static let instructions = """
    You label voice-meeting transcripts. Each line starts with its speaker: "You" (the device owner), or another participant — "Them", "Speaker N" or their name. Speech-to-text noise and misrecognized words are expected — infer the intended meaning. Always answer in the dominant language of the transcript itself.
    """

    /// Character budget fitting the ~4k-token on-device context window.
    private static let promptBudget = 5000

    /// Head+tail truncation: keeps the opening and the close of the meeting,
    /// where the topic and the decisions live. Mid-line cuts are fine — the
    /// instructions already tell the model to tolerate STT noise.
    private static func clipped(_ lines: [String]) -> String {
        let full = lines.joined(separator: "\n")
        if full.count <= promptBudget { return full }
        let half = promptBudget / 2
        return String(full.prefix(half)) + "\n[...]\n" + String(full.suffix(half))
    }
}

#if canImport(FoundationModels)
/// Guided-generation schema (#107). Prompt and guide texts were validated on
/// real transcripts in `experiments/enrichment` — keep their substance. The
/// type definitions matter: an earlier, looser wording misclassified
/// personal conversations as work.
@available(macOS 26.0, iOS 26.0, *)
@Generable
private enum MeetingType: String {
    case work
    case personal
}

@available(macOS 26.0, iOS 26.0, *)
@Generable
private struct GeneratedEnrichment {
    @Guide(description: "Short specific title naming the concrete conversation topic, max 6 words, in the transcript's dominant language. Name the actual subject, not a generic category.")
    var title: String
    @Guide(description: "personal = family, friends, relationships, health, errands, leisure, everyday life. work = job tasks, business deals, clients, colleagues, contracts, projects. If the conversation is mostly everyday life, it is personal even if a job is mentioned in passing.")
    var type: MeetingType
    @Guide(description: "Personal names of people mentioned in the conversation (people talked about or addressed). Proper names only — never pronouns, no roles, no companies, no invented names. Empty list if none.")
    var people: [String]
    @Guide(description: "Names of companies, organizations, or clients mentioned in the conversation. Real organization names only — no people, no roles, no invented names. Empty list if none.")
    var organizations: [String]
    @Guide(description: "1-2 short factual sentences: what was discussed and what was decided or planned, in the transcript's dominant language. Concrete facts only — never describe the tone, emotions, or the conversation itself.")
    var summary: String
}
#endif
