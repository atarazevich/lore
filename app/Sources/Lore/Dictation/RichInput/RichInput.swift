import Foundation

/// Where a dictation's items land in its words, and how the words come back out
/// again for cleanup (#192).
///
/// Everything here is a pure function over strings and seconds, so the placement
/// rule ("at the end of the clause that was being spoken when it happened") and
/// the cleanup rule ("only the spoken words go to the model") are testable
/// without a microphone, a model or a network.
enum RichInput {

    // MARK: - Position

    /// One spoken word's boundary: the second it ended at, and whether a
    /// clause ended with it — its own punctuation, or a pause long enough to
    /// hear before the next word.
    struct Word: Equatable, Sendable {
        let end: Double
        let endsClause: Bool
    }

    /// What ends a clause when the recogniser writes it.
    private static let clauseEnders: Set<Character> = [
        ".", ",", "!", "?", "\u{2026}", ":", ";",
    ]

    /// A pause at least this long reads as the end of a clause even with no
    /// punctuation to show for it. A full second, because the shorter pauses
    /// are the ones inside a sentence: a hesitation, an "uh", a breath before
    /// the word that was being searched for. At 0.3 s a screenshot taken while
    /// the speaker hesitated landed before the word he was reaching for.
    private static let clauseGap: Double = 1.0

    /// Every word of one transcription chunk, in order. Parakeet's tokens are
    /// sub-word pieces whose text carries the word boundary as a leading
    /// space, so a word runs from the first token that contributed a
    /// non-space character to it to the last.
    ///
    /// `audioOffset` is where this chunk starts in the dictation's audio — the
    /// timings a chunk returns are its own, and a 40 s dictation is two
    /// chunks. The chunk's last word has no next word here, so only its own
    /// punctuation can end its clause; the gap across a chunk seam is not this
    /// chunk's to measure.
    static func words(tokens: [TranscribedToken], audioOffset: Double) -> [Word] {
        struct Spoken {
            var text: String
            var start: Double
            var end: Double
        }
        var spoken: [Spoken] = []
        var pending: Spoken?
        for token in tokens {
            for character in token.text {
                if character.isWhitespace {
                    if let word = pending { spoken.append(word) }
                    pending = nil
                } else if pending == nil {
                    pending = Spoken(
                        text: String(character),
                        start: token.start + audioOffset,
                        end: token.end + audioOffset
                    )
                } else {
                    pending?.text.append(character)
                    pending?.end = token.end + audioOffset
                }
            }
        }
        if let word = pending { spoken.append(word) }

        return spoken.enumerated().map { index, word in
            let punctuated = word.text.last.map(clauseEnders.contains) ?? false
            let paused = index + 1 < spoken.count
                && spoken[index + 1].start - word.end >= clauseGap
            return Word(end: word.end, endsClause: punctuated || paused)
        }
    }

    /// How many words the item follows. Its own second is the earliest it may
    /// land; from there the placement runs forward to the first word that ends
    /// a clause and lands after that one, so a screenshot taken while the
    /// speaker was saying "чёрный квадрат" arrives after the quadrat, not
    /// between the two words. With no clause left after the instant — and with
    /// no timings at all — the item goes to the end of the text, which is the
    /// honest place for "somewhere after here".
    static func wordIndex(for offset: Double, words: [Word]) -> Int {
        guard !words.isEmpty else { return .max }
        var index = words.reduce(0) { $1.end <= offset ? $0 + 1 : $0 }
        // The instant already fell on a clause end; going further would be
        // moving the item for no reason.
        if index > 0, words[index - 1].endsClause { return index }
        while index < words.count {
            if words[index].endsClause { return index + 1 }
            index += 1
        }
        return .max
    }

    /// The character just past the `count`-th word of `text`; `endIndex` when
    /// the text has no more words than that.
    static func characterIndex(afterWord count: Int, in text: String) -> String.Index {
        guard count > 0 else { return text.startIndex }
        var words = 0
        var inWord = false
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if inWord {
                    inWord = false
                    words += 1
                    if words == count { return index }
                }
            } else {
                inWord = true
            }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    // MARK: - Compose

    /// One string: the spoken words with every kept item at the clause it
    /// happened in. Each item is its own block between blank lines, tagged by
    /// what it is, so the model reading the paste can tell what was spoken
    /// from what was inserted.
    ///
    /// Items whose file could not be written contribute nothing (`pasteText`
    /// nil) — a prompt never names a picture that is not there.
    static func compose(spoken: String, items: [DictationItem], words: [Word]) -> String {
        // Sorted by where they land, ties broken by the order they were
        // collected in — Swift's sort is not stable, and two things copied in
        // the same second must still arrive in the order they were copied.
        let placed = items
            .filter(\.included)
            .enumerated()
            .compactMap { order, item -> (index: String.Index, order: Int, text: String)? in
                // The path form: what `compose` builds is the dictation's
                // record — its history entry and what cleanup sees. The web
                // form is derived from it at paste time (`delivery`, #195).
                guard let text = item.pasteText(for: .path) else { return nil }
                let count = wordIndex(for: item.offset, words: words)
                return (characterIndex(afterWord: count, in: spoken), order, text)
            }
            .sorted { $0.index != $1.index ? $0.index < $1.index : $0.order < $1.order }
        guard !placed.isEmpty else { return spoken }

        var parts: [Part] = []
        var cursor = spoken.startIndex
        for insertion in placed {
            parts.append(.spoken(String(spoken[cursor..<insertion.index])))
            parts.append(.item(insertion.text))
            cursor = insertion.index
        }
        parts.append(.spoken(String(spoken[cursor...])))
        return join(parts)
    }

    private enum Part {
        case spoken(String)
        case item(String)
    }

    /// A blank line between every part — an inserted block stands on its own
    /// lines, and the speech around it keeps its own — and never a seam at the
    /// very start or the very end.
    private static func join(_ parts: [Part]) -> String {
        var out = ""
        for part in parts {
            let piece: String
            switch part {
            case .spoken(let raw): piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            case .item(let text): piece = text
            }
            guard !piece.isEmpty else { continue }
            if !out.isEmpty { out += "\n\n" }
            out += piece
        }
        return out
    }

    // MARK: - Deliver

    /// One step of a paste (#195). A web composer cannot be handed a picture
    /// inside a string, so a dictation that carries one arrives as a short
    /// sequence: the words up to the picture, the picture itself, the words
    /// after it.
    enum DeliveryStep: Equatable, Sendable {
        /// Words — the spoken text with `<copied>`/`<link>` and the tags that
        /// name the files, exactly as they will read in the composer.
        case text(String)
        /// Absolute paths, delivered as one pasteboard carrying one
        /// `public.file-url` item each: Chrome and WebKit expose every such
        /// item as a file under its real name, where image bytes on the
        /// pasteboard expose only the first picture.
        case files([String])
    }

    /// How a composed dictation reaches `target`.
    ///
    /// A terminal reads paths, so it gets what it has always got: one step,
    /// one paste, the text untouched. Everything else gets the same text with
    /// each picture's tag reduced to the filename the composer will show, cut
    /// at every picture so the file can be pasted where it was taken.
    ///
    /// The items are found by their own pasted text, searched forward from the
    /// previous cut — the same discipline as `split`, so a cleaned text (whose
    /// items came back verbatim) cuts exactly as the raw one does. An item that
    /// cannot be found is left alone rather than guessed at.
    static func delivery(
        text: String, items: [DictationItem], target: PasteTarget
    ) -> [DeliveryStep] {
        guard target == .web else { return text.isEmpty ? [] : [.text(text)] }

        var steps: [DeliveryStep] = []
        var pending = ""
        var run: [String] = []
        var cursor = text.startIndex

        // The files that follow the words already gathered. Emitting the words
        // first is what puts each tag in the composer before the attachment it
        // names.
        func flushRun() {
            guard !run.isEmpty else { return }
            if !pending.isEmpty {
                steps.append(.text(pending))
                pending = ""
            }
            steps.append(.files(run))
            run = []
        }

        for item in items where item.included {
            guard let needle = item.pasteText(for: .path), !needle.isEmpty,
                  let found = text.range(of: needle, range: cursor..<text.endIndex) else { continue }
            let between = String(text[cursor..<found.lowerBound])
            let attaches = item.kind.isFile && item.path != nil
            // Two pictures taken in the same breath travel in one paste; a word
            // spoken between them ends the run and starts a new one.
            if !attaches || !between.allSatisfy(\.isWhitespace) { flushRun() }
            pending += between
            pending += item.pasteText(for: attaches ? .web : .path) ?? needle
            if attaches, let path = item.path { run.append(path) }
            cursor = found.upperBound
        }
        flushRun()

        pending += String(text[cursor...])
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            steps.append(.text(pending))
        }
        return steps
    }

    // MARK: - Split (cleanup and translation never touch inserted material)

    /// A composed text cut back into the parts the model may see and the parts
    /// it may not. `segments` are the spoken words; `separators` are the items
    /// with the whitespace the composition put around them, kept verbatim.
    struct Split: Equatable, Sendable {
        let segments: [String]
        let separators: [String]

        /// True when there is nothing to protect — one segment, no items.
        var isWhole: Bool { separators.isEmpty }

        /// Put the text back together with the cleaned words in place of the
        /// spoken ones. Each cleaned segment is trimmed: the whitespace at the
        /// seams belongs to the separators, so a model that returns a trailing
        /// newline cannot add a paragraph break of its own.
        func reassembled(with cleaned: [String]) -> String {
            guard cleaned.count == segments.count else { return "" }
            var out = ""
            for (index, segment) in cleaned.enumerated() {
                out += segment.trimmingCharacters(in: .whitespacesAndNewlines)
                if index < separators.count { out += separators[index] }
            }
            return out
        }
    }

    /// Cut `text` at the items it carries. The items are found by their own
    /// pasted text, searched forward from the previous cut, so nothing needs to
    /// remember character offsets that a later edit would invalidate. An item
    /// that cannot be found is skipped rather than guessed at.
    static func split(_ text: String, items: [DictationItem]) -> Split {
        var segments: [String] = []
        var separators: [String] = []
        var cursor = text.startIndex
        for item in items where item.included {
            guard let needle = item.pasteText(for: .path), !needle.isEmpty,
                  let found = text.range(of: needle, range: cursor..<text.endIndex) else { continue }
            var start = found.lowerBound
            while start > cursor, text[text.index(before: start)].isWhitespace {
                start = text.index(before: start)
            }
            var end = found.upperBound
            while end < text.endIndex, text[end].isWhitespace {
                end = text.index(after: end)
            }
            segments.append(String(text[cursor..<start]))
            separators.append(String(text[start..<end]))
            cursor = end
        }
        segments.append(String(text[cursor...]))
        return Split(segments: segments, separators: separators)
    }
}
