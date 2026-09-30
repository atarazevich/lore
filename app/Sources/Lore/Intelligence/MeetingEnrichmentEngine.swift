import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

private let enrichLog = Logger(subsystem: "com.lore.app", category: "Enrichment")

#if canImport(FoundationModels)
/// Guided-generation schema (#107). Prompt and guide texts were validated on
/// real transcripts in `experiments/enrichment` — keep their substance. The
/// type definitions matter: an earlier, looser wording misclassified
/// personal conversations as work.
@available(macOS 26.0, *)
@Generable
private enum MeetingType: String {
    case work
    case personal
}

@available(macOS 26.0, *)
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

/// Meeting auto-enrichment (#107): after a meeting ends — and once per
/// existing meeting via the launch sweep — Apple Foundation Models generate,
/// entirely on-device, a topical title, a work/personal tag, people and
/// organization tags, and a 1–2 sentence summary.
///
/// `summary == nil` is the single idempotency rule: a session stays eligible
/// until a summary lands, so failures (model errors, app quit mid-write) are
/// silently retried by the next launch sweep. On macOS < 26 or with Apple
/// Intelligence unavailable, every entry point is a silent no-op.
///
/// Manual titles are never overwritten: only a nil title or the untouched
/// derived default (#58) is replaced.
actor MeetingEnrichmentEngine {
    /// What one run produced, whatever made it.
    struct Enrichment: Sendable {
        var title: String
        /// "work" or "personal".
        var type: String
        var people: [String]
        var organizations: [String]
        var summary: String
    }

    /// Prompt → enrichment. Production uses the on-device model; tests hand
    /// in their own.
    typealias Summarize = @Sendable (_ prompt: String) async throws -> Enrichment

    private let repository: SessionRepository
    /// UI refresh hook, called after a session's enrichment writes land.
    private let onEnriched: @Sendable () async -> Void
    private let summarize: Summarize?
    /// The latest run asked for per meeting (#269): only it may run again
    /// when the lines went stale under it.
    private var runs: [String: Int] = [:]

    init(
        repository: SessionRepository,
        onEnriched: @escaping @Sendable () async -> Void,
        summarize: Summarize? = nil
    ) {
        self.repository = repository
        self.onEnriched = onEnriched
        self.summarize = summarize
    }

    /// Whether a summary can be made now: macOS 26 with Apple Intelligence
    /// ready, or a summarizer handed in. Without it, a summary that exists is
    /// kept (#269).
    nonisolated var canSummarize: Bool {
        summarize != nil || Self.isAvailable
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// Enrich one session if it has a transcript and no summary yet. Actor
    /// isolation serializes concurrent triggers (finalize vs launch sweep);
    /// the summary check makes the loser a no-op.
    ///
    /// Lines that change while the model runs — a speaker pass settling, a
    /// naming (#269) — make the result stale; it is not written. The latest
    /// run asked for then runs once more on the lines as they read now, so a
    /// meeting is never left without a summary by its own names landing.
    func enrichIfNeeded(sessionID: String) async {
        guard canSummarize else { return }
        let run = (runs[sessionID] ?? 0) + 1
        runs[sessionID] = run
        for _ in 0..<2 {
            guard await enrichOnce(sessionID: sessionID), runs[sessionID] == run else { return }
        }
    }

    /// One run; true when its result was stale and not written.
    private func enrichOnce(sessionID: String) async -> Bool {
        let index = await repository.sessionIndex(sessionID: sessionID)
        guard index.summary == nil else { return false }
        // Names and turns, as the review reads them (#269).
        let lines = await repository.meetingTranscript(sessionID: sessionID).enrichmentLines
        guard !lines.isEmpty else { return false }

        do {
            let prompt = "Transcript:\n\(Self.clipped(lines))\n\nProduce the title, type, people, organizations, and summary."
            let result: Enrichment
            if let summarize {
                result = try await summarize(prompt)
            } else {
                result = try await Self.onDevice(prompt)
            }
            guard await apply(result, sessionID: sessionID, lines: lines) else { return true }
            enrichLog.debug("enriched \(sessionID, privacy: .private)")
            await onEnriched()
        } catch {
            // Silent skip (#107): summary stays nil, the next sweep retries
            // (e.g. model assets not downloaded yet, error 1013).
            enrichLog.debug("enrichment failed for \(sessionID, privacy: .private): \(error.localizedDescription, privacy: .private)")
        }
        return false
    }

    private struct Unavailable: Error {}

    private static func onDevice(_ prompt: String) async throws -> Enrichment {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw Unavailable() }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        let result = try await session.respond(to: prompt, generating: GeneratedEnrichment.self).content
        return Enrichment(
            title: result.title, type: result.type.rawValue, people: result.people,
            organizations: result.organizations, summary: result.summary)
        #else
        throw Unavailable()
        #endif
    }

    /// Launch backfill: every session with a transcript and no summary,
    /// one at a time. Empty-transcript sessions are skipped inside
    /// `enrichIfNeeded` (their summary stays nil, so they cost one transcript
    /// read per launch and nothing else).
    func sweep() async {
        for session in await repository.listSessions() where session.summary == nil {
            // Never touch the session being recorded right now.
            if let current = await repository.getCurrentSessionID(), current == session.id { continue }
            await enrichIfNeeded(sessionID: session.id)
        }
    }

    // MARK: - Applying results

    /// False, writing nothing, when the lines the result was made from are no
    /// longer what the meeting reads.
    private func apply(_ result: Enrichment, sessionID: String, lines: [String]) async -> Bool {
        // The model call takes seconds — re-load the index right before
        // writing so a rename or tag edit made during inference wins.
        let index = await repository.sessionIndex(sessionID: sessionID)
        // A summary that landed meanwhile means another trigger already
        // enriched this session — write nothing.
        guard index.summary == nil else { return true }
        guard await repository.meetingTranscript(sessionID: sessionID).enrichmentLines == lines else { return false }

        // Title: only nil or the untouched derived default (#58) is replaced —
        // anything else is a manual rename and is never overwritten.
        let generated = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleIsDefault = index.title.map { SessionIndex.isDefaultTitle($0, startedAt: index.startedAt) } ?? true
        if titleIsDefault && !generated.isEmpty {
            await repository.renameSession(sessionID: index.id, title: generated)
        }

        // Tags: appended behind whatever the user already set — pronouns and
        // junk the model emits as entities are dropped first (#131), then the
        // repository normalizes (case-insensitive dedupe, cap). A re-summary
        // after a naming (#269) appends too: generated tags cannot be told
        // from the user's, so a name the owner corrected can stay as a tag.
        let existing = index.tags ?? []
        let appended = Self.filteredTags(
            [result.type] + result.people + result.organizations
        )
        await repository.updateSessionTags(sessionID: index.id, tags: existing + appended)

        // Summary last: it is the enriched marker, so a partial apply
        // (app quit mid-write) is simply redone by the next sweep. An empty
        // summary is not persisted — the session stays eligible and the
        // next sweep retries, mirroring the title guard above.
        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return true }
        await repository.updateSessionSummary(sessionID: index.id, summary: summary)
        return true
    }

    // MARK: - Tag filtering (#131)

    /// Case-insensitive stoplist of Russian and English personal/possessive
    /// pronouns the on-device model occasionally emits as "people" on long
    /// noisy transcripts (#131). ё-less spellings included — STT and the
    /// model both drop the diaeresis.
    private static let pronounStoplist: Set<String> = [
        // Russian
        "я", "ты", "вы", "мы", "он", "она", "оно", "они",
        "мой", "моя", "моё", "мое", "мои",
        "твой", "твоя", "твоё", "твое", "твои",
        "ваш", "ваша", "ваше", "ваши",
        "наш", "наша", "наше", "наши",
        "его", "её", "ее", "их",
        "мне", "тебе", "нам", "вам", "ему", "ей", "им",
        "меня", "тебя", "нас", "вас", "него", "неё", "нее", "них",
        "себя", "свой", "своя", "своё", "свое", "свои",
        // English
        "i", "me", "you", "we", "they", "he", "she", "it",
        "my", "mine", "your", "yours", "our", "ours",
        "their", "theirs", "them", "us", "him", "her",
        "its", "his", "hers",
    ]

    /// Post-filter for generated tags (#131), engine-agnostic: drops
    /// pronouns, single-character and purely numeric candidates. Dedupe
    /// against existing (user-set) tags is not done here — the repository's
    /// `updateSessionTags` normalizes case-insensitively, first-wins.
    static func filteredTags(_ candidates: [String]) -> [String] {
        candidates.compactMap { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 1,
                  !trimmed.allSatisfy(\.isNumber),
                  !pronounStoplist.contains(trimmed.lowercased()) else { return nil }
            return trimmed
        }
    }

    // MARK: - Prompt assembly (validated in experiments/enrichment)

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
