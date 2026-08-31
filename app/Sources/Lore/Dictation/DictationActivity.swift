import Foundation
import Observation

/// Sendable snapshot of one dictation's fields needed for Activity aggregation
/// (#215) — copied out of the main-actor `DictationHistoryEntry` before
/// hopping to a detached task, per `SettingsView.measureAudioFolder`
/// (SettingsView.swift:669-686).
struct DictationActivitySample: Sendable {
    let timestamp: Date
    let text: String
    let durationSeconds: Double
}

/// One calendar day's rolled-up activity.
struct DictationDayActivity: Sendable {
    let day: Date
    var words: Int = 0
    var tokens: Int = 0
    var seconds: Double = 0
    var dictations: Int = 0
}

/// 25th/50th/75th percentile of non-zero day word counts — the boundaries
/// between heatmap levels 1–4 (level 0 is always "no dictation that day").
/// A named struct rather than a tuple for clarity at call sites.
struct DictationActivityLevelThresholds: Sendable {
    let q25: Double
    let q50: Double
    let q75: Double
}

/// Whole-history (or whole-period) roll-up backing the Activity pane: period
/// totals, per-day figures for the heatmap and its hover projection, and the
/// heatmap's 5-level intensity thresholds.
struct DictationActivitySummary: Sendable {
    /// Keyed by `Calendar.startOfDay` — only days with ≥1 dictation are present.
    let byDay: [Date: DictationDayActivity]
    let earliestDay: Date
    let totalWords: Int
    let totalTokens: Int
    let totalSeconds: Double
    let totalDictations: Int
    let peak: DictationDayActivity?
    let levelThresholds: DictationActivityLevelThresholds

    var activeDays: Int { byDay.count }

    /// 0...4 — matches `docs/design/prototypes/dictation-heatmap.html` v4's
    /// `levelFor`. 0 for a day with no dictation or with `words <= 0`.
    func level(forWordsOn day: Date) -> Int {
        let words = byDay[day]?.words ?? 0
        guard words > 0 else { return 0 }
        if Double(words) <= levelThresholds.q25 { return 1 }
        if Double(words) <= levelThresholds.q50 { return 2 }
        if Double(words) <= levelThresholds.q75 { return 3 }
        return 4
    }
}

/// Pure aggregation for the Dictation Activity pane (#215). Every function
/// here is `nonisolated` and side-effect-free so it can run inside
/// `Task.detached` off the main actor — ~1500 transcripts' worth of
/// whitespace-splitting is a main-thread hitch otherwise.
enum DictationActivityAggregator {
    /// o200k_base (GPT-5 tokenizer) measured over the full corpus on
    /// 2026-08-31: 230,034 tokens / 835,643 chars. No tokenizer dependency —
    /// the pane's tooltip calls this an estimate.
    static let tokensPerCharacter = 0.2753

    /// Population + text choice (#215 data rules): entries with status
    /// transcribed/cleaned whose `rawText ?? cleanedText` is non-empty.
    /// Never `displayText` — totals must not shift when a row's active
    /// version toggles.
    static func sample(from entry: DictationHistoryEntry) -> DictationActivitySample? {
        guard entry.status == .transcribed || entry.status == .cleaned else { return nil }
        guard let text = entry.rawText ?? entry.cleanedText, !text.isEmpty else { return nil }
        return DictationActivitySample(
            timestamp: entry.timestamp, text: text, durationSeconds: entry.durationSeconds
        )
    }

    /// Whitespace-split count (matches `ContentView.talkSplit`, ContentView.swift:415).
    static func words(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// `round(chars × 0.2753)`, per entry.
    static func tokens(in text: String) -> Int {
        Int((Double(text.count) * tokensPerCharacter).rounded())
    }

    static func summarize(
        entries: [DictationHistoryEntry], calendar: Calendar = .current
    ) -> DictationActivitySummary? {
        summarize(samples: entries.compactMap(sample(from:)), calendar: calendar)
    }

    static func summarize(
        samples: [DictationActivitySample], calendar: Calendar = .current
    ) -> DictationActivitySummary? {
        guard !samples.isEmpty else { return nil }

        var byDay: [Date: DictationDayActivity] = [:]
        for sample in samples {
            let day = calendar.startOfDay(for: sample.timestamp)
            var stats = byDay[day] ?? DictationDayActivity(day: day)
            stats.words += words(in: sample.text)
            stats.tokens += tokens(in: sample.text)
            stats.seconds += sample.durationSeconds
            stats.dictations += 1
            byDay[day] = stats
        }

        var totalWords = 0, totalTokens = 0, totalDictations = 0
        var totalSeconds: Double = 0
        var peak: DictationDayActivity?
        // Chronological order so a tie on peak words keeps the earlier day —
        // matches the prototype's `>` (never `>=`) scan.
        for stats in byDay.values.sorted(by: { $0.day < $1.day }) {
            totalWords += stats.words
            totalTokens += stats.tokens
            totalSeconds += stats.seconds
            totalDictations += stats.dictations
            if peak == nil || stats.words > peak!.words {
                peak = stats
            }
        }

        let nonZeroWords = byDay.values.map(\.words).filter { $0 > 0 }.sorted()
        return DictationActivitySummary(
            byDay: byDay,
            earliestDay: byDay.keys.min() ?? calendar.startOfDay(for: Date()),
            totalWords: totalWords,
            totalTokens: totalTokens,
            totalSeconds: totalSeconds,
            totalDictations: totalDictations,
            peak: peak,
            levelThresholds: quantileThresholds(nonZeroWords)
        )
    }

    /// 25th/50th/75th percentile via linear interpolation — matches the
    /// prototype's `quantile()` (numpy's default "linear" method).
    private static func quantileThresholds(_ sorted: [Int]) -> DictationActivityLevelThresholds {
        guard !sorted.isEmpty else { return DictationActivityLevelThresholds(q25: 0, q50: 0, q75: 0) }
        return DictationActivityLevelThresholds(
            q25: quantile(sorted, 0.25), q50: quantile(sorted, 0.5), q75: quantile(sorted, 0.75)
        )
    }

    private static func quantile(_ sorted: [Int], _ q: Double) -> Double {
        let position = Double(sorted.count - 1) * q
        let base = Int(position.rounded(.down))
        let rest = position - Double(base)
        guard base + 1 < sorted.count else { return Double(sorted[base]) }
        return Double(sorted[base]) + rest * Double(sorted[base + 1] - sorted[base])
    }
}

/// Memoized aggregation cache for the Activity pane (#215 review — F4): held
/// in `DictationView`'s persistent `@State`, the `HistoryProjectionCache`
/// pattern (DictationView.swift). `DictationActivityView` itself is only
/// mounted while the History/Activity switch is on Activity, so a `@State`
/// living on that view cannot survive a round trip back to History and
/// forces the ~1500-transcript aggregation to redo itself on every revisit;
/// this box, held one level up, survives that round trip. `@Observable` so
/// `DictationActivityView` picks up `summary` when the detached task
/// finishes, the same way it already reads `DictationHistory` — a plain
/// stored property, no `@Bindable`/`@ObservedObject` wrapper needed.
@MainActor
@Observable
final class DictationActivityCache {
    private(set) var summary: DictationActivitySummary?

    private struct Key: Equatable {
        let revision: Int
        let today: Date
    }
    private var key: Key?
    private var computeTask: Task<Void, Never>?

    /// Recomputes only when `(revision, today)` differs from the last call —
    /// an unchanged key is a no-op, not a re-aggregation. The word/token
    /// split still runs in a detached task off the main actor, the same
    /// shape as `SettingsView.measureAudioFolder` (SettingsView.swift:669-686).
    func ensure(entries: [DictationHistoryEntry], revision: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        let newKey = Key(revision: revision, today: today)
        guard key != newKey else { return }
        key = newKey
        computeTask?.cancel()
        let samples = entries.compactMap(DictationActivityAggregator.sample(from:))
        computeTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                DictationActivityAggregator.summarize(samples: samples)
            }.value
            guard !Task.isCancelled else { return }
            self?.summary = result
        }
    }
}
