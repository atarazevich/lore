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
    @Guide(description: "Personal names of people mentioned in the conversation (people talked about or addressed). Real names only — no roles, no companies, no invented names. Empty list if none.")
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
    private let repository: SessionRepository
    /// UI refresh hook, called after a session's enrichment writes land.
    private let onEnriched: @Sendable () async -> Void

    init(repository: SessionRepository, onEnriched: @escaping @Sendable () async -> Void) {
        self.repository = repository
        self.onEnriched = onEnriched
    }

    /// Enrich one session if it has a transcript and no summary yet. Actor
    /// isolation serializes concurrent triggers (finalize vs launch sweep);
    /// the summary check makes the loser a no-op.
    func enrichIfNeeded(sessionID: String) async {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        guard case .available = SystemLanguageModel.default.availability else { return }

        let detail = await repository.loadSession(id: sessionID)
        let index = detail.index
        guard index.summary == nil else { return }
        let lines = Self.transcriptLines(detail.transcript)
        guard !lines.isEmpty else { return }

        do {
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: Self.instructions
            )
            let transcript = Self.clipped(lines)
            let prompt = "Transcript:\n\(transcript)\n\nProduce the title, type, people, organizations, and summary."
            let result = try await session.respond(to: prompt, generating: GeneratedEnrichment.self).content
            await apply(result, sessionID: sessionID)
            enrichLog.debug("enriched \(sessionID, privacy: .private)")
            await onEnriched()
        } catch {
            // Silent skip (#107): summary stays nil, the next sweep retries
            // (e.g. model assets not downloaded yet, error 1013).
            enrichLog.debug("enrichment failed for \(sessionID, privacy: .private): \(error.localizedDescription, privacy: .private)")
        }
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

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func apply(_ result: GeneratedEnrichment, sessionID: String) async {
        // The model call takes seconds — re-load the index right before
        // writing so a rename or tag edit made during inference wins.
        let index = await repository.loadSession(id: sessionID).index
        // A summary that landed meanwhile means another trigger already
        // enriched this session — write nothing.
        guard index.summary == nil else { return }

        // Title: only nil or the untouched derived default (#58) is replaced —
        // anything else is a manual rename and is never overwritten.
        let generated = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleIsDefault = index.title == nil
            || index.title == SessionIndex.defaultTitle(startedAt: index.startedAt)
        if titleIsDefault && !generated.isEmpty {
            await repository.renameSession(sessionID: index.id, title: generated)
        }

        // Tags: appended behind whatever the user already set — the
        // repository normalizes (case-insensitive dedupe, cap).
        let appended = [result.type.rawValue] + result.people + result.organizations
        await repository.updateSessionTags(sessionID: index.id, tags: (index.tags ?? []) + appended)

        // Summary last: it is the enriched marker, so a partial apply
        // (app quit mid-write) is simply redone by the next sweep. An empty
        // summary is not persisted — the session stays eligible and the
        // next sweep retries, mirroring the title guard above.
        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        await repository.updateSessionSummary(sessionID: index.id, summary: summary)
    }
    #endif

    // MARK: - Prompt assembly (validated in experiments/enrichment)

    private static let instructions = """
    You label voice-meeting transcripts. The transcript has two sides: "You" (the device owner) and "Them"/"Speaker N" (other participants). Speech-to-text noise and misrecognized words are expected — infer the intended meaning. Always answer in the dominant language of the transcript itself.
    """

    /// Character budget fitting the ~4k-token on-device context window.
    private static let promptBudget = 5000

    private static func transcriptLines(_ records: [SessionRecord]) -> [String] {
        records.compactMap { record in
            let text = record.displayText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(record.speaker.displayLabel): \(text)"
        }
    }

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
