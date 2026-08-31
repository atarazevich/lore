import AppKit
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

    /// Review — A11d: an empty-string `rawText` (distinct from nil `rawText`)
    /// previously won `rawText ?? cleanedText` outright and then failed the
    /// `!text.isEmpty` guard, discarding a perfectly good `cleanedText`.
    func testFallsBackToCleanedTextWhenRawTextIsEmptyString() {
        let entry = makeEntry(day: "2026-08-01", rawText: "", cleanedText: "cleaned only")
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

    /// #220: a non-text-bearing entry (failed, or audio-only) is still a
    /// dictation and still took time — it is NOT dropped from the summary the
    /// way it is dropped from the words/tokens population. Only a truly empty
    /// history (no entries at all) returns nil.
    func testNonTextEntryStillCountsAsADictation() {
        let entries = [makeEntry(day: "2026-08-01", rawText: "x", status: .failed, durationSeconds: 7)]
        let summary = DictationActivityAggregator.summarize(entries: entries, calendar: utc)

        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.totalDictations, 1)
        XCTAssertEqual(summary?.totalWords, 0)
        XCTAssertEqual(summary?.totalSeconds, 7)
    }

    /// The Stats pane's "dictations" total must equal the history strip's
    /// "N entries" by construction — same source array, same count — even
    /// with a mix of statuses (some text-bearing, some not). This is the
    /// #220 assertion that closes the 1,489-vs-1,573 discrepancy.
    func testTotalDictationsEqualsHistoryEntryCount() {
        let entries = [
            makeEntry(day: "2026-08-01", rawText: "one two", status: .transcribed),
            makeEntry(day: "2026-08-01", rawText: nil, status: .failed),
            makeEntry(day: "2026-08-02", rawText: "x", status: .audioSaved),
            makeEntry(day: "2026-08-03", cleanedText: "three", status: .cleaned),
        ]
        let summary = DictationActivityAggregator.summarize(entries: entries, calendar: utc)

        XCTAssertEqual(summary?.totalDictations, entries.count)
    }

    /// Time counts ALL entries' durations, including ones with no text; words
    /// keep counting only the text-bearing entries — the two populations stay
    /// distinct even as dictations/time broaden (#220).
    func testTimeIncludesAllEntriesWordsStayTextOnly() {
        let entries = [
            makeEntry(day: "2026-08-01", rawText: "one two", status: .transcribed, durationSeconds: 5),
            makeEntry(day: "2026-08-01", rawText: "x", status: .audioSaved, durationSeconds: 9),
        ]
        let summary = DictationActivityAggregator.summarize(entries: entries, calendar: utc)

        XCTAssertEqual(summary?.totalSeconds, 14)
        XCTAssertEqual(summary?.totalWords, 2) // only the transcribed entry's text
        XCTAssertEqual(summary?.totalDictations, 2)
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

    /// Review — A1: a day with only a failed entry is in `byDay` (it has a
    /// dictation and took time) but is an uncolored level-0 heatmap cell
    /// (0 words) — it must not inflate "active days" past the number of
    /// colored cells on screen.
    func testActiveDaysCountsOnlyDaysWithWords() {
        let entries = [
            makeEntry(day: "2026-08-01", rawText: "one two three"),
            makeEntry(day: "2026-08-02", rawText: nil, status: .failed, durationSeconds: 4),
        ]
        let summary = DictationActivityAggregator.summarize(entries: entries, calendar: utc)!

        XCTAssertEqual(summary.byDay.count, 2)
        XCTAssertEqual(summary.activeDays, 1)
        let coloredCells = summary.byDay.keys.filter { summary.level(forWordsOn: $0) >= 1 }.count
        XCTAssertEqual(summary.activeDays, coloredCells)
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
        XCTAssertEqual(DictationActivityFormat.groupedNumber(144_929), "144,929")
    }

    // MARK: - Duration formatting boundaries (review — A12a: `duration` had
    // zero tests before this pass).

    func testDurationUnderAMinuteFloorsToZeroMinutes() {
        XCTAssertEqual(DictationActivityFormat.duration(59.9), "0 m")
    }

    func testDurationJustUnderAnHour() {
        XCTAssertEqual(DictationActivityFormat.duration(3599), "59 m")
    }

    func testDurationExactlyOneHourZeroPadsMinutes() {
        XCTAssertEqual(DictationActivityFormat.duration(3600), "1 h 00 m")
    }

    func testDurationMultiHourZeroPadsSingleDigitMinutes() {
        // 7261s = 121m01s -> 2h01m; the zero-pad matters for a multi-hour
        // total too, not only exactly-on-the-hour totals.
        XCTAssertEqual(DictationActivityFormat.duration(7261), "2 h 01 m")
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

    // MARK: - Reserved column widths (#220): "measure the string, not a magic
    // number" — each width must equal a fresh AppKit measurement of
    // "1,000,000" (or the widest duration shape) in the exact font the pane
    // renders with, not a hand-picked point value that could silently drift
    // from the font. Calls `DictationActivityView.measuredWidth` directly
    // (review — A5) instead of keeping a token-identical private copy of it
    // here, which could drift from the production formula unnoticed.

    /// One assertion per reserved width, looped rather than three
    /// near-identical test methods (review — A5): each row is the exact
    /// `(constant, template, size, weight, tracking)` the production value
    /// was built from.
    func testReservedWidthsAreMeasuredExactly() {
        let cases: [(name: String, actual: CGFloat, text: String, size: CGFloat, weight: NSFont.Weight, tracking: CGFloat)] = [
            ("wordsColumnWidth", DictationActivityView.wordsColumnWidth, "1,000,000", 58, .bold, -1),
            ("quadrantNumberWidth", DictationActivityView.quadrantNumberWidth, "1,000,000", 24, .bold, 0),
            ("quadrantDurationWidth", DictationActivityView.quadrantDurationWidth, "999 h 59 m", 24, .bold, 0),
        ]
        for testCase in cases {
            XCTAssertEqual(
                testCase.actual,
                DictationActivityView.measuredWidth(
                    testCase.text, size: testCase.size, weight: testCase.weight, tracking: testCase.tracking
                ),
                accuracy: 0.01,
                testCase.name
            )
        }
    }

    /// The reservation must actually be wide enough for real content —
    /// otherwise "measured" just moves the magic number one level down.
    func testReservedWidthsFitRealisticValues() {
        XCTAssertGreaterThanOrEqual(
            DictationActivityView.wordsColumnWidth,
            DictationActivityView.measuredWidth("146,902", size: 58, weight: .bold)
        )
        XCTAssertGreaterThanOrEqual(
            DictationActivityView.quadrantDurationWidth,
            DictationActivityView.measuredWidth("24 h 02 m", size: 24, weight: .bold)
        )
    }

    // MARK: - Heatmap week grid (review — A12b: `weekColumns` and
    // `monthLabelPositions` shipped both the A1 and A3 divergences from the
    // prototype while private and untested; made internal for this pass).

    /// A `startOfDay` local date, built the same way `summary.earliestDay`
    /// and the pane's `today` are — via `Calendar.current`, never a pinned
    /// UTC calendar, since `weekColumns` itself uses `Calendar.current`.
    private func localDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.startOfDay(for: Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!)
    }

    func testWeekColumnsStartsOnTheMondayOnOrBeforeTheEarliestDay() {
        let earliest = localDay(2026, 8, 5) // a Wednesday
        let today = localDay(2026, 8, 29)
        let weeks = DictationActivityView.weekColumns(from: earliest, through: today)

        XCTAssertEqual(weeks.first?.first, localDay(2026, 8, 3)) // the Monday on/before Aug 5
        // The first column is a full week — days before the data even
        // starts still get a (level-0) slot, matching the GitHub-heatmap
        // idiom of a partial-looking first column.
        XCTAssertEqual(weeks.first?.count, 7)
    }

    func testWeekColumnsTrimsDaysAfterToday() {
        // Review — A1: the grid must never carry (or hover-target) a day
        // after today.
        let earliest = localDay(2026, 8, 24) // a Monday
        let today = localDay(2026, 8, 29) // a Saturday
        let weeks = DictationActivityView.weekColumns(from: earliest, through: today)

        let lastWeek = try! XCTUnwrap(weeks.last)
        XCTAssertEqual(lastWeek.last, today)
        XCTAssertFalse(lastWeek.contains(localDay(2026, 8, 30)))
        XCTAssertEqual(lastWeek.count, 6) // Mon 24 ... Sat 29 — no Sunday 30
    }

    /// Review — A3, real-corpus shape: the grid's first week starts on the
    /// last Monday of April, so May's first candidate week lands only one
    /// column after April's label — too close (< 26pt) — and per the
    /// prototype (dictation-heatmap.html:353-358) that suppression is
    /// PERMANENT for the rest of May, because `lastMonth` updates before the
    /// gap check: every later May week already shares May's month number and
    /// never re-enters the check. June is far enough from April's label to
    /// get its own tick, and July/August follow normally.
    func testMonthLabelPositionsSkipsAPermanentlySuppressedMonth() {
        let earliest = localDay(2026, 4, 27) // the Monday on/before May 1
        let today = localDay(2026, 8, 29)
        let weeks = DictationActivityView.weekColumns(from: earliest, through: today)

        let labels = DictationActivityView.monthLabelPositions(weeks: weeks)
        let months = labels.map { DictationActivityView.monthLabel($0.id) }

        XCTAssertEqual(months, ["Apr", "Jun", "Jul", "Aug"]) // May never appears
        XCTAssertEqual(labels.first?.x, 0) // Apr is week 0
    }

    // MARK: - Tokens tooltip state (#222): pure hover/pin transitions,
    // extracted so they're testable without driving SwiftUI hover events.

    func testTooltipNotPresentedInitially() {
        XCTAssertFalse(DictationActivityView.TokensTooltipState().isPresented)
    }

    func testTooltipPresentedWhileHoveringAlone() {
        var state = DictationActivityView.TokensTooltipState()
        state.isHovering = true
        XCTAssertTrue(state.isPresented)
    }

    func testTooltipPresentedWhilePinnedAlone() {
        var state = DictationActivityView.TokensTooltipState()
        state.isPinned = true
        XCTAssertTrue(state.isPresented)
    }

    /// A click while already hovering pins the tooltip; the hover ending on
    /// the next mouse move must not un-pin it.
    func testClickWhileHoveringPinsAndSurvivesHoverEnding() {
        var state = DictationActivityView.TokensTooltipState()
        state.isHovering = true
        state.togglePinned()
        state.isHovering = false
        XCTAssertTrue(state.isPresented)
    }

    /// AppKit's dismissal (click-away, Esc) always calls the binding's
    /// setter with `false` — that must clear both drivers, so a stale pin
    /// can't silently reopen the popover on the next hover.
    func testSetPresentedFalseClearsBothHoverAndPin() {
        var state = DictationActivityView.TokensTooltipState()
        state.isHovering = true
        state.isPinned = true
        state.setPresented(false)
        XCTAssertFalse(state.isHovering)
        XCTAssertFalse(state.isPinned)
        XCTAssertFalse(state.isPresented)
    }

    /// The binding is one-directional: `.popover(isPresented:)` never calls
    /// the setter with `true` (only SwiftUI-internal dismissal calls it, and
    /// always with `false`), so `setPresented(true)` is defensively a no-op
    /// rather than a way to reopen a closed tooltip out of band.
    func testSetPresentedTrueIsANoOp() {
        var state = DictationActivityView.TokensTooltipState()
        state.setPresented(true)
        XCTAssertFalse(state.isPresented)
    }

    // MARK: - Tokens hover-delay arming (review — B1): an un-pinning click
    // while the mouse never left the tokens line must close the tooltip and
    // keep it closed until a genuine leave + re-enter — not reopen 150ms
    // later when the *original* hover session's delay task finally fires.
    // Drives `TokensHoverArming` and `TokensTooltipState` directly, exactly
    // as the view's `.onHover`/`.task(id:)`/tap-gesture glue would, without a
    // real SwiftUI runtime or a real 150ms sleep.

    func testUnpinWhileStillHoveringStaysClosedUntilPointerLeavesAndReenters() {
        var arming = DictationActivityView.TokensHoverArming()
        var tooltip = DictationActivityView.TokensTooltipState()

        // Hover begins; the delay is allowed to fire and shows the tooltip.
        arming.setHovering(true)
        XCTAssertTrue(arming.shouldShowAfterDelay)
        tooltip.isHovering = true

        // A click while still hovering pins it.
        tooltip.togglePinned()
        XCTAssertTrue(tooltip.isPresented)

        // A second click un-pins it — the mouse never left the line, so the
        // original hover session (whose id never changed) is still "live".
        tooltip.togglePinned()
        XCTAssertFalse(tooltip.isPinned)
        tooltip.isHovering = false
        arming.disarmForClosingClick()

        // The disarmed session must never show again, even though the
        // pointer is still on the line — this is what a stale delay task
        // would otherwise re-check 150ms after the closing click.
        XCTAssertFalse(arming.shouldShowAfterDelay)
        XCTAssertFalse(tooltip.isPresented)

        // Leaving the line re-arms the next session...
        arming.setHovering(false)
        XCTAssertFalse(arming.shouldShowAfterDelay)

        // ...and re-entering is a fresh session, allowed to show again.
        arming.setHovering(true)
        XCTAssertTrue(arming.shouldShowAfterDelay)
    }

    /// A closing click while NOT hovering (e.g. a future non-mouse pin
    /// toggle) must not disarm a session that hasn't started yet.
    func testDisarmForClosingClickIsANoOpWhileNotHovering() {
        var arming = DictationActivityView.TokensHoverArming()
        arming.disarmForClosingClick()
        arming.setHovering(true)
        XCTAssertTrue(arming.shouldShowAfterDelay)
    }
}
