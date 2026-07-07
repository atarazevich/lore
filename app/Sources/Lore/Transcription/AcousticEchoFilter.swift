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
    static func matches(
        normalizedYou: String,
        normalizedThem: String,
        timeDelta: TimeInterval
    ) -> Bool {
        if isEligible(normalizedYou) && isEligible(normalizedThem) {
            guard timeDelta >= 0, timeDelta <= window else { return false }
            let similarity = TextSimilarity.jaccard(normalizedYou, normalizedThem)
            return similarity >= similarityThreshold
                || normalizedYou.contains(normalizedThem)
                || normalizedThem.contains(normalizedYou)
        }

        return abs(timeDelta) <= shortTextWindow
            && !normalizedYou.isEmpty
            && normalizedYou == normalizedThem
    }

    /// Suppress mic records that are acoustic echoes of system records.
    /// Modifies `micRecords` in place, removing entries that match.
    static func suppress(
        micRecords: inout [SessionRecord],
        against sysRecords: [SessionRecord]
    ) {
        micRecords.removeAll { micRecord in
            let normalizedYou = TextSimilarity.normalizedText(micRecord.text)

            for sysRecord in sysRecords.reversed() {
                let timeDelta = micRecord.timestamp.timeIntervalSince(sysRecord.timestamp)
                guard timeDelta >= 0 else { continue }
                guard timeDelta <= window else { break }

                let normalizedThem = TextSimilarity.normalizedText(sysRecord.text)
                if matches(
                    normalizedYou: normalizedYou,
                    normalizedThem: normalizedThem,
                    timeDelta: timeDelta
                ) {
                    diagLog(
                        "[ECHO-FILTER] suppressed mic record as echo " +
                        "dt=\(String(format: "%.2f", timeDelta)) " +
                        "mic='\(micRecord.text.prefix(80))' sys='\(sysRecord.text.prefix(80))'"
                    )
                    return true
                }
            }
            return false
        }
    }

    private static func isEligible(_ normalizedText: String) -> Bool {
        let wordCount = normalizedText.split(separator: " ").count
        return wordCount >= minimumWordCount || normalizedText.count >= minimumCharacterCount
    }
}
