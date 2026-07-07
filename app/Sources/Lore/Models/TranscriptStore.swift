import Foundation
import Observation

@Observable
@MainActor
final class TranscriptStore {
    @ObservationIgnored nonisolated(unsafe) private var _utterances: [Utterance] = []
    private(set) var utterances: [Utterance] {
        get { access(keyPath: \.utterances); return _utterances }
        set { withMutation(keyPath: \.utterances) { _utterances = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _volatileYouText = ""
    var volatileYouText: String {
        get { access(keyPath: \.volatileYouText); return _volatileYouText }
        set { withMutation(keyPath: \.volatileYouText) { _volatileYouText = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _volatileThemText = ""
    var volatileThemText: String {
        get { access(keyPath: \.volatileThemText); return _volatileThemText }
        set { withMutation(keyPath: \.volatileThemText) { _volatileThemText = newValue } }
    }

    @discardableResult
    func append(_ utterance: Utterance) -> Bool {
        guard !shouldSuppressAcousticEcho(utterance) else { return false }
        removeEchoedByIncoming(utterance)
        utterances.append(utterance)
        return true
    }

    /// Update an existing utterance's refined text by ID.
    func updateRefinedText(id: UUID, refinedText: String?, status: RefinementStatus) {
        guard let index = utterances.firstIndex(where: { $0.id == id }) else { return }
        utterances[index] = utterances[index].withRefinement(text: refinedText, status: status)
    }

    func clear() {
        utterances.removeAll()
        volatileYouText = ""
        volatileThemText = ""
    }

    var lastRemoteUtterance: Utterance? {
        utterances.last(where: { $0.speaker.isRemote })
    }

    /// Last N utterances for prompt context
    var recentUtterances: [Utterance] {
        Array(utterances.suffix(10))
    }

    /// Recent 6 utterances for gate/generation prompts
    var recentExchange: [Utterance] {
        Array(utterances.suffix(6))
    }

    /// Recent remote-only utterances for trigger analysis
    var recentRemoteUtterances: [Utterance] {
        utterances.suffix(10).filter { $0.speaker.isRemote }
    }

    /// Reverse echo check: when a remote utterance arrives and matches a recent
    /// mic utterance, the mic version is the echo (speaker bleed) — remove it.
    /// This handles the common case where the mic transcriber processes faster
    /// than the system audio transcriber.
    /// The match rule (incl. the short-text strict branch, #59) lives in
    /// `AcousticEchoFilter.matches` — shared with the forward path and batch.
    private func removeEchoedByIncoming(_ utterance: Utterance) {
        guard utterance.speaker.isRemote else { return }

        let normalizedIncoming = TextSimilarity.normalizedText(utterance.text)

        // Walk backwards through recent utterances looking for mic echoes.
        // Cap at 20 entries for performance; the time window will exit earlier in practice.
        var indicesToRemove: [Int] = []
        for i in stride(from: utterances.count - 1, through: max(0, utterances.count - 20), by: -1) {
            let existing = utterances[i]
            guard existing.speaker == .you else { continue }
            let timeDelta = utterance.timestamp.timeIntervalSince(existing.timestamp)

            let normalizedExisting = TextSimilarity.normalizedText(existing.text)
            guard AcousticEchoFilter.matches(
                normalizedYou: normalizedExisting,
                normalizedThem: normalizedIncoming,
                timeDelta: timeDelta
            ) else { continue }

            diagLog(
                "[TRANSCRIPT-ECHO] removing mic echo retroactively " +
                "dt=\(String(format: "%.2f", timeDelta)) " +
                "you='\(existing.text.prefix(80))' them='\(utterance.text.prefix(80))'"
            )
            indicesToRemove.append(i)
        }

        // Remove in reverse order to preserve indices
        for i in indicesToRemove.sorted().reversed() {
            utterances.remove(at: i)
        }
    }

    private func shouldSuppressAcousticEcho(_ utterance: Utterance) -> Bool {
        guard utterance.speaker == .you else { return false }

        let normalizedYouText = TextSimilarity.normalizedText(utterance.text)

        for candidate in utterances.reversed() where candidate.speaker.isRemote {
            let timeDelta = utterance.timestamp.timeIntervalSince(candidate.timestamp)
            guard timeDelta >= 0 else { continue }
            guard timeDelta <= AcousticEchoFilter.window else { break }

            let normalizedThemText = TextSimilarity.normalizedText(candidate.text)
            guard AcousticEchoFilter.matches(
                normalizedYou: normalizedYouText,
                normalizedThem: normalizedThemText,
                timeDelta: timeDelta
            ) else { continue }

            diagLog(
                "[TRANSCRIPT-ECHO] dropped mic utterance as system-audio echo " +
                "dt=\(String(format: "%.2f", timeDelta)) " +
                "you='\(utterance.text.prefix(80))' them='\(candidate.text.prefix(80))'"
            )
            return true
        }

        return false
    }
}
