import Foundation
import LoreCore
import LoreFormat
import os

private let enrichLog = Logger(subsystem: "com.lore.app", category: "Enrichment")

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
    /// Transcript lines → enrichment. Production uses the on-device model;
    /// tests hand in their own.
    typealias Summarize = @Sendable (_ lines: [String]) async throws -> MeetingEnrichment.Result

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
        summarize != nil || MeetingEnrichment.isAvailable
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
            let result: MeetingEnrichment.Result
            if let summarize {
                result = try await summarize(lines)
            } else if let generated = try await MeetingEnrichment.generate(forTranscript: lines) {
                result = generated
            } else {
                enrichLog.debug("enrichment failed for \(sessionID, privacy: .private): on-device model unavailable")
                return false
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
    private func apply(_ result: MeetingEnrichment.Result, sessionID: String, lines: [String]) async -> Bool {
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
            [result.type.rawValue] + result.people + result.organizations
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
}
