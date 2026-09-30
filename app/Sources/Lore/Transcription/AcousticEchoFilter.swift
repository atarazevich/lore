import Foundation

/// Shared acoustic echo suppression logic.
/// Detects when mic (YOU) utterances are echoes of system (THEM) audio based on
/// Jaccard word-set similarity and substring containment; sub-threshold (short)
/// texts use a strict verbatim rule instead (#59).
enum AcousticEchoFilter {

    static let window: TimeInterval = 4.0
    static let similarityThreshold: Double = 0.35
    static let minimumWordCount: Int = 4
    static let minimumCharacterCount: Int = 20
    /// Tighter window for the short-text strict branch (#59): the observed
    /// leak ("Orders." → "Orders.") arrived 1.0s apart.
    static let shortTextWindow: TimeInterval = 2.0

    /// One echo decision for a you/them pair — shared by the live forward
    /// and retroactive paths (TranscriptStore) and the batch pass below, so
    /// the rule exists exactly once.
    ///
    /// - Both texts eligible (≥ word/char minimums): Jaccard ≥ threshold or
    ///   substring containment, within `0...window` — asymmetric by design:
    ///   mic echo trails system audio for eligible-length texts.
    /// - Either sub-threshold (#59): strict branch — exact normalized
    ///   equality within `±shortTextWindow`. Negative delta is accepted
    ///   because a mic echo can finalize with a LATER timestamp than the
    ///   system utterance while arriving earlier (isDelayed remote path), so
    ///   the retroactive check sees timeDelta < 0 for the real leak pair.
    ///   Jaccard/containment are deliberately NOT loosened for shorts
    ///   ("but" ⊂ anything). Accepted residual: the user saying exactly
    ///   "Yeah." within 2s of a remote "yeah" loses one backchannel word —
    ///   cheaper than attributing remote audio to the user.
    ///
    /// Texts must already be normalized via `TextSimilarity.normalizedText`.
    ///
    /// Returns the Jaccard score when the pair is an echo, `nil` when it is not.
    /// Callers that want the score for a diagnostic take it from here rather than
    /// recomputing it: an extra O(n) pass per suppressed utterance, purely to
    /// populate an event, is work the product does not need.
    static func echoScore(
        normalizedYou: String,
        normalizedThem: String,
        timeDelta: TimeInterval
    ) -> Double? {
        if isEligible(normalizedYou) && isEligible(normalizedThem) {
            guard timeDelta >= 0, timeDelta <= window else { return nil }
            let similarity = TextSimilarity.jaccard(normalizedYou, normalizedThem)
            let isEcho = similarity >= similarityThreshold
                || normalizedYou.contains(normalizedThem)
                || normalizedThem.contains(normalizedYou)
            return isEcho ? similarity : nil
        }

        let strictMatch = abs(timeDelta) <= shortTextWindow
            && !normalizedYou.isEmpty
            && normalizedYou == normalizedThem
        // Exact normalized equality — a Jaccard of 1 by definition, not recomputed.
        return strictMatch ? 1.0 : nil
    }

    /// Bool-only view of `echoScore`, for callers (and tests) that only ask "is it".
    static func matches(
        normalizedYou: String,
        normalizedThem: String,
        timeDelta: TimeInterval
    ) -> Bool {
        echoScore(normalizedYou: normalizedYou, normalizedThem: normalizedThem, timeDelta: timeDelta) != nil
    }

    /// Suppress mic lines that are acoustic echoes of system records. Each mic
    /// line comes with where its speech ends. Modifies `micLines` in place,
    /// removing entries that match.
    ///
    /// Either line may start first (#273): each track is cut into lines on its
    /// own, so a mic copy can start before the system line it repeats. A mic
    /// line that starts first is an echo only when the system line starts
    /// within `window` and while the mic line is still speaking: the same
    /// sound overlaps on both tracks, a reply starts after the line it answers
    /// ends, so a real exchange of the same words is kept. Such a pair is
    /// judged by Jaccard alone for eligible texts — containment would let a
    /// short phrase the other side repeats delete a long line of the owner's —
    /// and by the strict branch, at its signed delta, for short ones.
    ///
    /// Emits ONE summary event for the whole pass (#82). Per-utterance events would
    /// evict the launch, permission and identity history the ring exists to keep.
    ///
    /// `parts` gives each line's record and where its speech ends; a line may
    /// carry more (the batch pass's keep their word timings, #269).
    static func suppress<Line>(
        _ micLines: inout [Line],
        against sysRecords: [SessionRecord],
        by parts: (Line) -> (record: SessionRecord, end: Date)
    ) {
        var tally = EchoTally()

        micLines.removeAll { line in
            let (micRecord, micEnd) = parts(line)
            let normalizedYou = TextSimilarity.normalizedText(micRecord.text)

            for sysRecord in sysRecords.reversed() {
                let timeDelta = micRecord.timestamp.timeIntervalSince(sysRecord.timestamp)
                guard timeDelta <= window else { break }
                guard timeDelta >= 0 || (-timeDelta <= window && sysRecord.timestamp < micEnd) else { continue }

                let normalizedThem = TextSimilarity.normalizedText(sysRecord.text)
                let score = echoScore(normalizedYou: normalizedYou, normalizedThem: normalizedThem, timeDelta: timeDelta)
                    ?? micFirstJaccard(normalizedYou, normalizedThem, timeDelta: timeDelta)
                if let jaccard = score {
                    tally.add(jaccard: jaccard)
                    return true
                }
            }
            return false
        }

        tally.recordSummary(path: .batch)
    }

    /// A mic-first pair of eligible texts: Jaccard alone, no containment.
    private static func micFirstJaccard(_ you: String, _ them: String, timeDelta: TimeInterval) -> Double? {
        guard timeDelta < 0, isEligible(you), isEligible(them) else { return nil }
        let similarity = TextSimilarity.jaccard(you, them)
        return similarity >= similarityThreshold ? similarity : nil
    }

    /// Running aggregate of one echo-suppression pass. Numbers only — never the
    /// suppressed text, which is the user's and the remote party's speech.
    struct EchoTally {
        private(set) var count = 0
        private var jaccardSum: Double = 0

        mutating func add(jaccard: Double) {
            count += 1
            jaccardSum += jaccard
        }

        mutating func reset() {
            count = 0
            jaccardSum = 0
        }

        var meanJaccard: Double { count == 0 ? 0 : jaccardSum / Double(count) }

        /// Emit the summary if anything was suppressed, then reset.
        mutating func recordSummary(path: DiagEvent.EchoPath) {
            guard count > 0 else { return }
            DiagStore.record(.echoSuppressed(path: path, count: count, meanJaccard: meanJaccard))
            reset()
        }
    }

    private static func isEligible(_ normalizedText: String) -> Bool {
        let wordCount = normalizedText.split(separator: " ").count
        return wordCount >= minimumWordCount || normalizedText.count >= minimumCharacterCount
    }
}
