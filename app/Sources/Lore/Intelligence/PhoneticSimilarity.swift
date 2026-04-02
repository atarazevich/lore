import Foundation

enum CorrectionType {
    case same           // no change needed
    case misrecognition // phonetically similar — add to vocabulary
    case contentEdit    // intentional content change — just update text
}

struct PhoneticSimilarity {
    // Latin + Cyrillic consonants
    private static let consonants: Set<Character> = Set(
        "bcdfghjklmnpqrstvwxyz" + "\u{0431}\u{0432}\u{0433}\u{0434}\u{0436}\u{0437}\u{043a}\u{043b}\u{043c}\u{043d}\u{043f}\u{0440}\u{0441}\u{0442}\u{0444}\u{0445}\u{0446}\u{0447}\u{0448}\u{0449}"
    )

    /// Jaccard similarity of consonant sets (0.0 - 1.0).
    static func consonantOverlap(_ a: String, _ b: String) -> Double {
        let aSet = Set(a.lowercased().filter { consonants.contains($0) })
        let bSet = Set(b.lowercased().filter { consonants.contains($0) })
        guard !aSet.isEmpty || !bSet.isEmpty else { return 0 }
        return Double(aSet.intersection(bSet).count) / Double(aSet.union(bSet).count)
    }

    /// Classify an island based on size and phonetic similarity.
    /// baseThreshold comes from settings (default 0.5).
    static func classifyIsland(
        originalWords: [String],
        editedWords: [String],
        baseThreshold: Double
    ) -> CorrectionType {
        // Asymmetric (deletion or insertion) → content edit
        if originalWords.isEmpty || editedWords.isEmpty { return .contentEdit }

        let size = max(originalWords.count, editedWords.count)
        if size > 3 { return .contentEdit }

        // Minimum length on the corrected form (joined, no spaces)
        let origJoined = originalWords.joined()
        let editJoined = editedWords.joined()
        if editJoined.count < 4 { return .contentEdit }

        // Case-only change → same, not a vocabulary candidate
        if origJoined.lowercased() == editJoined.lowercased() { return .same }

        // Graduated threshold from base
        let threshold: Double
        switch size {
        case 1: threshold = baseThreshold + 0.1
        case 2: threshold = baseThreshold
        case 3: threshold = baseThreshold - 0.15
        default: return .contentEdit
        }

        let similarity = consonantOverlap(origJoined, editJoined)
        return similarity >= threshold ? .misrecognition : .contentEdit
    }

    /// Legacy single-word classify — kept for backward compatibility.
    static func classify(original: String, correction: String) -> CorrectionType {
        classifyIsland(originalWords: [original], editedWords: [correction], baseThreshold: 0.5)
    }
}

// MARK: - Text Diff (word-level LCS with island extraction)

struct TextDiff {
    struct Island {
        let originalWords: [String]  // what was there (can be empty for insertions)
        let editedWords: [String]    // what it became (can be empty for deletions)
    }

    /// Strip leading/trailing punctuation from a word for comparison purposes.
    private static func stripPunctuation(_ word: String) -> String {
        var chars = Array(word)
        while let first = chars.first, first.isPunctuation { chars.removeFirst() }
        while let last = chars.last, last.isPunctuation { chars.removeLast() }
        return String(chars)
    }

    /// Tokenize text into words by splitting on whitespace.
    static func tokenize(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Compute LCS table indices. Returns the LCS as pairs of (originalIndex, editedIndex).
    /// Comparison uses stripped-punctuation, case-insensitive matching.
    private static func lcsIndices(original: [String], edited: [String]) -> [(Int, Int)] {
        let m = original.count
        let n = edited.count
        guard m > 0 && n > 0 else { return [] }
        // Build LCS length table
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                let a = stripPunctuation(original[i - 1]).lowercased()
                let b = stripPunctuation(edited[j - 1]).lowercased()
                if a == b {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        // Backtrack to find actual LCS pairs
        var pairs: [(Int, Int)] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            let a = stripPunctuation(original[i - 1]).lowercased()
            let b = stripPunctuation(edited[j - 1]).lowercased()
            if a == b {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    /// Find changed islands between original and edited text.
    /// Returns nil if >10 islands (bail-out — too many changes for classification).
    static func findIslands(original: String, edited: String) -> [Island]? {
        let origWords = tokenize(original)
        let editWords = tokenize(edited)

        let anchors = lcsIndices(original: origWords, edited: editWords)

        var islands: [Island] = []
        var oi = 0  // current position in original
        var ei = 0  // current position in edited

        for (anchorO, anchorE) in anchors {
            // Collect words before this anchor
            let origGap = Array(origWords[oi..<anchorO])
            let editGap = Array(editWords[ei..<anchorE])
            if !origGap.isEmpty || !editGap.isEmpty {
                islands.append(Island(originalWords: origGap, editedWords: editGap))
            }
            oi = anchorO + 1
            ei = anchorE + 1
        }

        // Trailing words after the last anchor
        let origTail = Array(origWords[oi...])
        let editTail = Array(editWords[ei...])
        if !origTail.isEmpty || !editTail.isEmpty {
            islands.append(Island(originalWords: origTail, editedWords: editTail))
        }

        // Bail-out: too many islands means a rewrite, not correction
        if islands.count > 10 { return nil }

        return islands
    }
}
