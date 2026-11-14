import Foundation

/// The recognizer's mark for a character it has no token for (#355): Parakeet
/// Ultra writes it where a dash or a quote belongs between words, and where ё
/// belongs inside one. It carries nothing the reader can use, so recognized
/// text never shows it: the backend drops it from what it hears, and the
/// readers drop it from what was stored before, leaving the files as they are.
public enum UnknownToken {
    public static let literal = "<unk>"

    /// `text` without the literal `<unk>`, and without the one space it leaves:
    /// " <unk> " → " ", "<unk>X<unk>" → "X", "вс<unk>." → "вс.", "слово <unk>." →
    /// "слово.". A space goes before a newline does, so lines never merge,
    /// and a token alone on its line takes the line with it. No other
    /// character changes: a real "<" or "unk" stays, and so does whitespace that
    /// was there already.
    public static func removed(from text: String) -> String {
        guard text.contains(literal) else { return text }
        var result = text
        while let range = result.range(of: literal) {
            let before = range.lowerBound > result.startIndex ? result.index(before: range.lowerBound) : nil
            let after = range.upperBound < result.endIndex ? range.upperBound : nil
            let beforeChar = before.map { result[$0] }
            let afterChar = after.map { result[$0] }
            func isSpace(_ c: Character?) -> Bool { c.map { $0.isWhitespace && !$0.isNewline } ?? false }
            var cut = range
            if let before, isSpace(beforeChar), afterChar.map({ $0.isWhitespace || closers.contains($0) }) ?? true {
                // "a <unk> b", "a <unk>", "a <unk>.": the space before was the token's.
                cut = before..<range.upperBound
            } else if let after, afterChar?.isWhitespace == true, beforeChar?.isNewline ?? true {
                // "<unk> b", "a\n<unk> b", "a\n<unk>\nb": the gap after goes, so
                // no edge gap and no new blank line; the newline before stays.
                cut = range.lowerBound..<result.index(after: after)
            }
            result.removeSubrange(cut)
        }
        return result
    }

    /// Punctuation that closes onto the word before it, so no space stands before it.
    private static let closers: Set<Character> = [".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "»", "”", "’"]
}
