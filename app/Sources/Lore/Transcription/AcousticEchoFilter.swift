import Foundation

/// Shared acoustic echo suppression logic.
/// Detects when mic (YOU) utterances are echoes of system (THEM) audio based on
/// Jaccard word-set similarity and substring containment.
enum AcousticEchoFilter {

    static let defaultWindow: TimeInterval = 4.0
    static let defaultSimilarityThreshold: Double = 0.35
    static let defaultMinimumWordCount: Int = 4
    static let defaultMinimumCharacterCount: Int = 20

    /// Suppress mic records that are acoustic echoes of system records.
    /// Modifies `micRecords` in place, removing entries that match.
    static func suppress(
        micRecords: inout [SessionRecord],
        against sysRecords: [SessionRecord],
        window: TimeInterval = defaultWindow,
        similarityThreshold: Double = defaultSimilarityThreshold,
        minimumWordCount: Int = defaultMinimumWordCount,
        minimumCharacterCount: Int = defaultMinimumCharacterCount
    ) {
        micRecords.removeAll { micRecord in
            let normalizedYou = TextSimilarity.normalizedText(micRecord.text)
            guard isEligible(normalizedYou, minimumWordCount: minimumWordCount, minimumCharacterCount: minimumCharacterCount) else {
                return false
            }

            for sysRecord in sysRecords.reversed() {
                let timeDelta = micRecord.timestamp.timeIntervalSince(sysRecord.timestamp)
                guard timeDelta >= 0 else { continue }
                guard timeDelta <= window else { break }

                let normalizedThem = TextSimilarity.normalizedText(sysRecord.text)
                guard isEligible(normalizedThem, minimumWordCount: minimumWordCount, minimumCharacterCount: minimumCharacterCount) else {
                    continue
                }

                let similarity = TextSimilarity.jaccard(normalizedYou, normalizedThem)
                let containsOther =
                    normalizedYou.contains(normalizedThem) ||
                    normalizedThem.contains(normalizedYou)

                if similarity >= similarityThreshold || containsOther {
                    diagLog(
                        "[ECHO-FILTER] suppressed mic record as echo " +
                        "dt=\(String(format: "%.2f", timeDelta)) " +
                        "sim=\(String(format: "%.2f", similarity)) " +
                        "mic='\(micRecord.text.prefix(80))' sys='\(sysRecord.text.prefix(80))'"
                    )
                    return true
                }
            }
            return false
        }
    }

    private static func isEligible(
        _ normalizedText: String,
        minimumWordCount: Int,
        minimumCharacterCount: Int
    ) -> Bool {
        let wordCount = normalizedText.split(separator: " ").count
        return wordCount >= minimumWordCount || normalizedText.count >= minimumCharacterCount
    }
}
