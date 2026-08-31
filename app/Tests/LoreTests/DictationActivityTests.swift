import SwiftUI
import XCTest
@testable import LoreKit

/// Aggregation for the Dictation Activity pane (#215): population/text-choice
/// rules, word/token counting, day bucketing, and the heatmap's quantile
/// levels. `DictationActivityAggregator` is pure (no persistence), so these
/// tests build `DictationHistoryEntry` values directly — no isolated storage
/// needed (contrast `DictationHistoryTests`, which exercises the on-disk store).
final class DictationActivityTests: XCTestCase {

    /// Fixed UTC calendar so day bucketing doesn't depend on the machine's
    /// local time zone.
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func dateFor(_ day: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: day)!
    }

    /// Noon in the machine's own (non-UTC-pinned) calendar — for the
    /// locale-pinned display formatters (#215 review — F8), which render in
    /// the system time zone by design (they must agree with the day
    /// bucketing elsewhere in the pane, which also uses `Calendar.current`).
    /// Noon keeps the calendar day stable across any real-world offset.
    private func localDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func makeEntry(
        day: String,
        rawText: String? = nil,
        cleanedText: String? = nil,
        status: DictationEntryStatus = .transcribed,
        activeVersion: DictationVersion = .raw,
        durationSeconds: Double = 10
    ) -> DictationHistoryEntry {
        var entry = DictationHistoryEntry(timestamp: dateFor(day), durationSeconds: durationSeconds)
        entry.status = status
        entry.rawText = rawText
        entry.cleanedText = cleanedText
        entry.activeVersion = activeVersion
        return entry
    }

    // MARK: - Population + raw-vs-cleaned text choice (#215 data rules)

    /// Counting must use `rawText ?? cleanedText`, never `displayText` —
    /// totals must not shift when a row's active version toggles.
    func testUsesRawTextRegardlessOfActiveVersion() {
        let entry = makeEntry(
            day: "2026-08-01", rawText: "one two three", cleanedText: "One. Two. Three.",
            activeVersion: .cleaned
        )
        XCTAssertEqual(DictationActivityAggregator.sample(from: entry)?.text, "one two three")
    }

    func testFallsBackToCleanedTextWhenNoRawText() {
        let entry = makeEntry(day: "2026-08-01", cleanedText: "cleaned only")
        XCTAssertEqual(DictationActivityAggregator.sample(from: entry)?.text, "cleaned only")
    }

    func testExcludesAudioSavedAndFailedStatuses() {
        let audioSaved = makeEntry(day: "2026-08-01", rawText: "x", status: .audioSaved)
        let failed = makeEntry(day: "2026-08-01", rawText: "x", status: .failed)
        XCTAssertNil(DictationActivityAggregator.sample(from: audioSaved))
        XCTAssertNil(DictationActivityAggregator.sample(from: failed))
    }

    func testExcludesEmptyText() {
        let entry = makeEntry(day: "2026-08-01", rawText: "")
        XCTAssertNil(DictationActivityAggregator.sample(from: entry))
    }

    // MARK: - Word counting (whitespace-split)

    func testWordsIsWhitespaceSplitCount() {
        XCTAssertEqual(DictationActivityAggregator.words(in: "one two  three\nfour\tfive"), 5)
    }

    // MARK: - Token rounding: round(chars × 0.2753), per entry

    func testTokensRoundsPerEntry() {
        XCTAssertEqual(DictationActivityAggregator.tokens(in: "0123456789"), 3) // 2.753 -> 3
        XCTAssertEqual(DictationActivityAggregator.tokens(in: "abcd"), 1) // 1.1012 -> 1
    }

    // MARK: - Day bucketing

    func testDayBucketingSumsEntriesOnSameDayAndSeparatesOthers() {
        let entries = [
            makeEntry(day: "2026-08-01", rawText: "one two", durationSeconds: 5),
            makeEntry(day: "2026-08-01", rawText: "three four five", durationSeconds: 7),
            makeEntry(day: "2026-08-02", rawText: "six", durationSeconds: 3),
        ]
        let summary = DictationActivityAggregator.summarize(entries: entries, calendar: utc)

        XCTAssertEqual(summary?.activeDays, 2)
        let aug1 = utc.startOfDay(for: dateFor("2026-08-01"))
        let aug2 = utc.startOfDay(for: dateFor("2026-08-02"))
        XCTAssertEqual(summary?.byDay[aug1]?.words, 5)
        XCTAssertEqual(summary?.byDay[aug1]?.dictations, 2)
        XCTAssertEqual(summary?.byDay[aug1]?.seconds, 12)
        XCTAssertEqual(summary?.byDay[aug2]?.words, 1)
        XCTAssertEqual(summary?.totalWords, 6)
        XCTAssertEqual(summary?.totalDictations, 3)
        XCTAssertEqual(summary?.totalSeconds, 15)
    }

    // MARK: - Empty history / single day

    func testEmptyHistoryReturnsNilSummary() {
        XCTAssertNil(DictationActivityAggregator.summarize(entries: [], calendar: utc))
    }

    /// Zero entries survive the population filter (all audio-only/failed) —
    /// must render the same quiet empty state as truly empty history.
    func testHistoryWithNoQualifyingEntriesReturnsNilSummary() {
        let entries = [makeEntry(day: "2026-08-01", rawText: "x", status: .failed)]
        XCTAssertNil(DictationActivityAggregator.summarize(entries: entries, calendar: utc))
    }

    func testSingleDayHistory() {
        let entries = [makeEntry(day: "2026-08-01", rawText: "one two three", durationSeconds: 42)]
        let summary = DictationActivityAggregator.summarize(entries: entries, calendar: utc)

        XCTAssertEqual(summary?.activeDays, 1)
        XCTAssertEqual(summary?.totalWords, 3)
        XCTAssertEqual(summary?.totalDictations, 1)
        XCTAssertEqual(summary?.peak?.words, 3)
        XCTAssertEqual(summary?.earliestDay, utc.startOfDay(for: dateFor("2026-08-01")))
        // One non-zero day collapses all three quantiles to its own value, so
        // it always lands in level 1 (value <= q25) — never crashes, never 0.
        XCTAssertEqual(summary?.level(forWordsOn: utc.startOfDay(for: dateFor("2026-08-01"))), 1)
    }

    // MARK: - Quantile levels

    func testQuantileLevelsAcrossFiveDays() {
        // Non-zero word counts 10/20/30/40/50 -> linear-interpolation
        // quantiles q25=20, q50=30, q75=40 (matches the prototype's `quantile()`).
        let entries = (1...5).map { day in
            makeEntry(
                day: "2026-08-0\(day)",
                rawText: Array(repeating: "w", count: day * 10).joined(separator: " ")
            )
        }
        let summary = DictationActivityAggregator.summarize(entries: entries, calendar: utc)!
        func level(_ day: Int) -> Int {
            summary.level(forWordsOn: utc.startOfDay(for: dateFor("2026-08-0\(day)")))
        }

        XCTAssertEqual(level(1), 1) // 10 <= 20
        XCTAssertEqual(level(2), 1) // 20 <= 20
        XCTAssertEqual(level(3), 2) // 30 <= 30
        XCTAssertEqual(level(4), 3) // 40 <= 40
        XCTAssertEqual(level(5), 4) // 50 > 40
        // A day with no dictation at all is level 0 — distinct from every
        // active day, and never an out-of-bounds lookup.
        XCTAssertEqual(summary.level(forWordsOn: utc.startOfDay(for: dateFor("2026-08-06"))), 0)
    }

    // MARK: - Peak tie-break

    func testPeakTiesKeepTheEarlierDay() {
        let entries = [
            makeEntry(day: "2026-08-02", rawText: "one two three"),
            makeEntry(day: "2026-08-01", rawText: "one two three"),
        ]
        let summary = DictationActivityAggregator.summarize(entries: entries, calendar: utc)
        XCTAssertEqual(summary?.peak?.day, utc.startOfDay(for: dateFor("2026-08-01")))
    }

    // MARK: - Locale-pinned display formatting (#215 review — F8: replaces
    // four `DateFormatter` statics + a `NumberFormatter` wrapper with
    // `.formatted(...)` pinned to en_US, so the design's English copy
    // survives a different system locale).

    func testGroupedNumberFormatting() {
        XCTAssertEqual(DictationActivityView.groupedNumber(144_929), "144,929")
    }

    func testDayLabelFormatting() {
        // Aug 29, 2026 is a Saturday.
        XCTAssertEqual(DictationActivityView.dayLabel(localDate(2026, 8, 29)), "sat, aug 29")
    }

    func testMonthDayYearLabelFormatting() {
        XCTAssertEqual(DictationActivityView.monthDayYearLabel(localDate(2026, 8, 29)), "aug 29, 2026")
    }

    func testMonthDayLabelFormatting() {
        XCTAssertEqual(DictationActivityView.monthDayLabel(localDate(2026, 8, 29)), "aug 29")
    }

    /// Heatmap month ticks stay title-case, matching the prototype's axis
    /// labels — the one place this pane doesn't lowercase.
    func testMonthLabelStaysTitleCase() {
        XCTAssertEqual(DictationActivityView.monthLabel(localDate(2026, 8, 29)), "Aug")
    }
}
