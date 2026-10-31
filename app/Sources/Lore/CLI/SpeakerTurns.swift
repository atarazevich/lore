import Foundation
import LoreCore

/// `lore transcribe --speakers` (#276): transcribed words and each word's
/// voice (`FileSpeakers`) in, the transcript as speaker turns out. A pure
/// function over seconds, so the rules are testable without a model.
enum SpeakerTurns {
    /// One paragraph per turn, `[mm:ss] Speaker N: text` (`[h:mm:ss]` from an
    /// hour on — the transcript view's own stamp), speakers counted from 1 in
    /// order of first appearance. Consecutive words of one voice make a turn.
    /// A word with no voice takes the previous word's — the first known
    /// voice's, at the start — so no word is dropped and no turn is
    /// unattributed. With no voice at all, everything is Speaker 1's.
    static func text(words: [TimedWord], voices: [String?]) -> String {
        var voice = voices.lazy.compactMap { $0 }.first ?? ""
        var numbers: [String: Int] = [:]
        var turns: [(speaker: Int, start: Double, text: String)] = []
        for (word, known) in zip(words, voices) {
            voice = known ?? voice
            let number = numbers[voice] ?? numbers.count + 1
            numbers[voice] = number
            if turns.last?.speaker == number {
                turns[turns.count - 1].text += " " + word.text
            } else {
                turns.append((number, word.start, word.text))
            }
        }
        return turns.map { "[\(ElapsedStamp.label($0.start))] Speaker \($0.speaker): \($0.text)" }
            .joined(separator: "\n\n")
    }
}
