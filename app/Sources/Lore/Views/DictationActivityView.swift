import SwiftUI

/// Dictation Activity pane (#215): a whole-history roll-up — a giant words
/// total, a 2×2 quadrant of secondary stats, and a per-day heatmap with
/// hover projection. Reached via the History/Activity switch in
/// `DictationView`. Design authority:
/// `docs/design/prototypes/dictation-heatmap.html` v4 (the approved canvas,
/// "D" layout, in the lore app skin) — matched pixel-for-pixel per
/// `.claude/rules/ui-design-first.md`.
struct DictationActivityView: View {
    let history: DictationHistory
    /// Memoization box held in `DictationView`'s persistent `@State` (#215
    /// review — F4): survives this view being torn down and rebuilt on every
    /// History/Activity round trip, so an unchanged `(revision, today)` key
    /// does not re-aggregate.
    let cache: DictationActivityCache
    /// Gates aggregation the same way `DictationView` gates its search key
    /// monitor (DictationView.swift:128-139): while the shell shows another
    /// destination, or Activity has never been opened (this view is then
    /// simply not in the tree, since `DictationView` only builds it when the
    /// switch is on Activity), no aggregation runs.
    var isActiveInShell: Bool

    @State private var hoveredDay: Date?

    /// Memoization key (#215 "How it fits"): follows `HistoryProjectionCache`
    /// (DictationView.swift) — recompute only when the history mutates or the
    /// calendar day flips. `isActive` folds in the destination-visibility
    /// gate so a background revision bump while the shell shows Settings
    /// does not trigger the detached aggregation either.
    private struct ComputeKey: Equatable {
        let revision: Int
        let today: Date
        let isActive: Bool
    }

    var body: some View {
        Group {
            if let summary = cache.summary {
                content(summary)
            } else {
                emptyState
            }
        }
        .task(id: ComputeKey(
            revision: history.revision,
            today: Calendar.current.startOfDay(for: Date()),
            isActive: isActiveInShell
        )) {
            guard isActiveInShell else { return }
            cache.ensure(entries: history.entries, revision: history.revision)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(LoreTheme.TextColor.faint)
            Text("No dictation activity yet")
                .font(LoreTheme.Typography.body)
                .foregroundStyle(LoreTheme.TextColor.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ summary: DictationActivitySummary) -> some View {
        let projected = hoveredDay.map { summary.byDay[$0] ?? DictationDayActivity(day: $0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                periodRow(summary: summary)
                hairline(LoreTheme.Surface.line3)
                statQuadrant(summary: summary, projected: projected)
                hairline(LoreTheme.Surface.line2)
                heatmapSection(summary: summary)
            }
            .padding(.horizontal, 26)
            .padding(.top, 16)
            .padding(.bottom, 22)
        }
    }

    /// Right-aligned period label; swaps for the hovered day's date, no
    /// layout shift (`.period-row`, prototype v4).
    private func periodRow(summary: DictationActivitySummary) -> some View {
        HStack {
            Spacer()
            Text(periodLabel(summary: summary))
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .padding(.bottom, 14)
    }

    private func periodLabel(summary: DictationActivitySummary) -> String {
        if let hoveredDay {
            return Self.dayLabel(hoveredDay)
        }
        return "since " + Self.monthDayYearLabel(summary.earliestDay)
    }

    // MARK: - Stat quadrant (`.quadrant`, prototype v4)

    private func statQuadrant(summary: DictationActivitySummary, projected: DictationDayActivity?) -> some View {
        let words = projected?.words ?? summary.totalWords
        let tokens = projected?.tokens ?? summary.totalTokens
        let seconds = projected?.seconds ?? summary.totalSeconds
        let dictations = projected?.dictations ?? summary.totalDictations
        let dimmed = hoveredDay != nil

        // Content-driven widths rather than the canvas's exact 1.5:1 / 1:0.7
        // flex ratios: SwiftUI's `.frame(maxWidth: .infinity)` splits leftover
        // space equally regardless of `layoutPriority` (that only breaks ties
        // under space pressure, not proportional division), so replicating a
        // CSS flex ratio exactly would need a measure-then-apply
        // GeometryReader pass for a cosmetic width difference between two
        // short numeric labels. The giant 58pt numeral already dominates the
        // row on its own natural width; only the primary cell is unconstrained
        // (sized to content), the secondary quadrant fills the remainder.
        return HStack(alignment: .top, spacing: 0) {
            // Primary cell: giant words + tokens companion line.
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.groupedNumber(words))
                    .font(LoreTheme.Typography.mono(58, weight: .bold))
                    .tracking(-1)
                    .foregroundStyle(Color.white.opacity(0.92))
                Text("words")
                    .font(.system(size: 10))
                    .tracking(1.4)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.top, 10)
                HStack(spacing: 6) {
                    Text(Self.groupedNumber(tokens))
                        .font(LoreTheme.Typography.mono(13, weight: .semibold))
                        .foregroundStyle(LoreTheme.Accent.blue)
                    Text("tokens")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LoreTheme.Accent.blue)
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .help("≈ o200k_base (GPT-5 tokenizer), estimated")
                }
                .padding(.top, 5)
            }
            .padding(.trailing, 24)
            .padding(.vertical, 20)
            .fixedSize(horizontal: true, vertical: false)

            hairline(LoreTheme.Surface.line2, vertical: true)

            // 2×2 secondary quadrant: time/dictations, active days/peak.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    quadrantCell(value: DictationActivityFormat.duration(seconds), label: "dictation time")
                    hairline(LoreTheme.Surface.line2, vertical: true)
                    quadrantCell(value: Self.groupedNumber(dictations), label: "dictations")
                }
                hairline(LoreTheme.Surface.line2)
                HStack(spacing: 0) {
                    quadrantCell(
                        value: Self.groupedNumber(summary.activeDays), label: "active days"
                    )
                    .opacity(dimmed ? 0.4 : 1)
                    hairline(LoreTheme.Surface.line2, vertical: true)
                    quadrantCell(
                        value: Self.groupedNumber(summary.peak?.words ?? 0),
                        label: "peak" + peakDateSuffix(summary: summary)
                    )
                    .opacity(dimmed ? 0.4 : 1)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func peakDateSuffix(summary: DictationActivitySummary) -> String {
        guard let peak = summary.peak else { return "" }
        return " · " + Self.monthDayLabel(peak.day)
    }

    private func quadrantCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(LoreTheme.Typography.mono(24, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.9))
                .fixedSize()
            Text(label)
                .font(.system(size: 9))
                .tracking(1.26)
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .padding(.leading, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Heatmap (`.heatmap`, prototype v4)

    private static let cellSize: CGFloat = 16
    private static let cellGap: CGFloat = 3
    private static var cellStep: CGFloat { cellSize + cellGap }

    private func heatmapSection(summary: DictationActivitySummary) -> some View {
        let weeks = Self.weekColumns(from: summary.earliestDay, through: Calendar.current.startOfDay(for: Date()))
        return VStack(alignment: .trailing, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    dayOfWeekLabels
                    VStack(alignment: .leading, spacing: 10) {
                        monthLabels(weeks: weeks)
                        heatmapGrid(weeks: weeks, summary: summary)
                    }
                }
            }
            legend(summary: summary)
        }
        .padding(.top, 26)
    }

    private var dayOfWeekLabels: some View {
        VStack(alignment: .trailing, spacing: Self.cellGap) {
            ForEach(["mon", "", "wed", "", "fri", "", ""], id: \.self) { label in
                Text(label)
                    .font(.system(size: 10))
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(height: Self.cellSize)
            }
        }
        .frame(width: 30, alignment: .trailing)
        .padding(.top, 13 + 10) // month-label row height + the grid's row gap (F3)
    }

    private func monthLabels(weeks: [[Date]]) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(
                width: CGFloat(weeks.count) * Self.cellStep, height: 13
            )
            ForEach(Self.monthLabelPositions(weeks: weeks)) { label in
                Text(label.text)
                    .font(.system(size: 10))
                    .tracking(1)
                    .foregroundStyle(Color.white.opacity(0.4))
                    .offset(x: label.x)
            }
        }
    }

    private struct MonthLabelPosition: Identifiable {
        let id: Date
        let text: String
        let x: CGFloat
    }

    /// One label per month, skipping a label that would sit within 26pt of
    /// the previous one (matches the prototype's `MIN_LABEL_GAP`). Computed
    /// as plain data first, then rendered — mutating local state from inside
    /// a `ForEach` view builder is fragile and unnecessary here.
    private static func monthLabelPositions(weeks: [[Date]]) -> [MonthLabelPosition] {
        var result: [MonthLabelPosition] = []
        var lastMonth = -1
        var lastLabelX: CGFloat = -.infinity
        let calendar = Calendar.current
        for (index, week) in weeks.enumerated() {
            guard let firstDay = week.first else { continue }
            let month = calendar.component(.month, from: firstDay)
            guard month != lastMonth else { continue }
            let x = CGFloat(index) * cellStep
            guard x - lastLabelX >= 26 else { continue }
            lastMonth = month
            lastLabelX = x
            result.append(MonthLabelPosition(id: firstDay, text: monthLabel(firstDay), x: x))
        }
        return result
    }

    /// Hover-enter sets `hoveredDay` per cell; leaving the *grid* (not each
    /// cell) clears it — matches the prototype's per-cell `mouseenter` +
    /// one `mouseleave` on the grid container (#215 review — F2). Clearing on
    /// each cell's own hover-exit made the stat block flash back to period
    /// totals while the pointer crossed the 3pt gap between adjacent cells.
    private func heatmapGrid(weeks: [[Date]], summary: DictationActivitySummary) -> some View {
        HStack(alignment: .top, spacing: Self.cellGap) {
            ForEach(weeks, id: \.self) { week in
                VStack(spacing: Self.cellGap) {
                    ForEach(week, id: \.self) { day in
                        heatmapCell(day: day, summary: summary)
                    }
                }
            }
        }
        .onHover { hovering in
            if !hovering { hoveredDay = nil }
        }
    }

    private func heatmapCell(day: Date, summary: DictationActivitySummary) -> some View {
        let level = summary.level(forWordsOn: day)
        let isHovered = hoveredDay == day
        return RoundedRectangle(cornerRadius: 2)
            .fill(Self.levelColor(level))
            .frame(width: Self.cellSize, height: Self.cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.white.opacity(isHovered ? 0.4 : 0), lineWidth: 1)
            )
            .onHover { hovering in
                if hovering { hoveredDay = day }
            }
    }

    /// l1–l3 are `LoreTheme.Accent.blue` at rising opacity; l4 is
    /// `LoreTheme.Accent.blue` at full opacity — one blue token for the whole
    /// ramp (#215 "How it fits": "Ramp uses LoreTheme.Accent.blue only"),
    /// not the prototype-authority canvas's separate #3d9bff for l4.
    private static func levelColor(_ level: Int) -> Color {
        switch level {
        case 1: LoreTheme.Accent.blue.opacity(0.25)
        case 2: LoreTheme.Accent.blue.opacity(0.5)
        case 3: LoreTheme.Accent.blue.opacity(0.75)
        case 4: LoreTheme.Accent.blue
        default: LoreTheme.Surface.hover
        }
    }

    private func legend(summary: DictationActivitySummary) -> some View {
        HStack(spacing: 6) {
            Text("0")
            ForEach(0...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.levelColor(level))
                    .frame(width: Self.cellSize, height: Self.cellSize)
            }
            Text("\(Self.groupedNumber(summary.peak?.words ?? 0)) words")
        }
        .font(.system(size: 10))
        .tracking(0.8)
        .foregroundStyle(Color.white.opacity(0.4))
    }

    // MARK: - Hairlines
    // The design calls for two hairline strengths stronger than
    // `LoreTheme.Surface.line` (.10): `LoreTheme.Surface.line2` (.12) inside
    // the stat block/quadrant and `LoreTheme.Surface.line3` (.25) above it,
    // under the period label — named tokens, not literal opacities (#215
    // review — F7).

    private func hairline(_ color: Color, vertical: Bool = false) -> some View {
        Rectangle()
            .fill(color)
            .frame(
                width: vertical ? 1 : nil,
                height: vertical ? nil : 1
            )
            .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
    }

    // MARK: - Formatting
    // `.formatted(...)` pinned to `en_US` (#215 review — F8, replaces four
    // `DateFormatter` statics + a `NumberFormatter` wrapper): the design's
    // English copy ("aug 29", "144,929") must not drift with the system
    // locale. `internal` (not `private`) so `DictationActivityTests` can
    // assert the exact rendered strings.

    static let locale = Locale(identifier: "en_US")

    static func groupedNumber(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    /// Hovered-day label, e.g. "sat, aug 29" (`.period-row` while projecting).
    static func dayLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated).month(.abbreviated).day())
            .lowercased()
    }

    /// "since aug 29, 2026" period label.
    static func monthDayYearLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).month(.abbreviated).day().year())
            .lowercased()
    }

    /// "peak · aug 29" suffix.
    static func monthDayLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).month(.abbreviated).day())
            .lowercased()
    }

    /// Heatmap month tick — stays title-case, matching the prototype's axis
    /// labels ("May", "Jun"), unlike the lowercase house style used elsewhere.
    static func monthLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).month(.abbreviated))
    }

    /// Monday-through-Sunday week columns spanning the Monday on/before
    /// `earliestDay` through `today` inclusive — the heatmap's span, derived
    /// from the data itself (never hardcoded), extended to today so a quiet
    /// day still shows on the grid.
    private static func weekColumns(from earliestDay: Date, through today: Date) -> [[Date]] {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: earliestDay) // 1=Sun...7=Sat
        let offsetFromMonday = (weekday + 5) % 7 // Mon->0 ... Sun->6
        guard let gridStart = calendar.date(byAdding: .day, value: -offsetFromMonday, to: earliestDay) else {
            return [[earliestDay]]
        }

        var weeks: [[Date]] = []
        var cursor = gridStart
        while cursor <= today {
            var week: [Date] = []
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: cursor) else { continue }
                week.append(day)
            }
            weeks.append(week)
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return weeks
    }
}

/// Floor-based duration formatting shared by the Activity pane's giant/side
/// stats: "N m" under an hour, else "H h MM m" (minutes zero-padded).
enum DictationActivityFormat {
    static func duration(_ totalSeconds: Double) -> String {
        let totalMinutes = Int(totalSeconds / 60) // truncates toward zero == floor for non-negative input
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard hours > 0 else { return "\(minutes) m" }
        return String(format: "%d h %02d m", hours, minutes)
    }
}
