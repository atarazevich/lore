import SwiftUI

/// Live transcript in the Lore design (MREC-11/12): speaker rows with a 64px
/// label column ("You" blue, diarized remotes keep the current palette),
/// 13px text, max-width 720. Interim (volatile) partials render as a dimmed
/// row with a blinking blue caret. Rows are keyed by utterance ID so
/// retroactive replacement (issue #19 sliding window) and echo-suppression
/// removals (MREC-14) re-render cleanly without confusing row identity.
struct TranscriptView: View {
    let utterances: [Utterance]
    let volatileYouText: String
    let volatileThemText: String
    /// Recording start for the elapsed stamps (#63) — the live session's
    /// `metadata.startedAt` while recording; nil after stop, when the anchor
    /// falls back to the first utterance's timestamp (matching what
    /// finalization persists as the session's startedAt).
    let startedAt: Date?
    var showSearch: Bool = false

    @State private var searchText = ""
    @State private var autoScrollEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredUtterances: [Utterance] {
        guard !searchText.isEmpty else { return utterances }
        return utterances.filter {
            $0.displayText.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var isSearching: Bool {
        showSearch && !searchText.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if showSearch {
                searchBar
                LoreDivider()
            }
            transcriptScrollView
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(LoreTheme.TextColor.faint)
            TextField("Search transcript…", text: $searchText)
                .textFieldStyle(.plain)
                .font(LoreTheme.Typography.secondary)
                .foregroundStyle(LoreTheme.TextColor.primary)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LoreTheme.TextColor.faint)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            LoreTheme.Surface.line
                .frame(width: 1, height: 14)

            Button {
                autoScrollEnabled.toggle()
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 11))
                    .foregroundStyle(autoScrollEnabled ? LoreTheme.TextColor.muted
                                                       : LoreTheme.Accent.red)
            }
            .buttonStyle(.plain)
            .help(autoScrollEnabled ? "Pause auto-scroll" : "Resume auto-scroll")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let visible = filteredUtterances
                if visible.isEmpty && isSearching {
                    Text("No matches")
                        .font(LoreTheme.Typography.secondary)
                        .foregroundStyle(LoreTheme.TextColor.muted)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    // Anchor from the full list, not the search-filtered one —
                    // stamps must not shift while searching.
                    let anchor = ElapsedStamp.anchor(
                        startedAt: startedAt,
                        firstTimestamp: utterances.first?.timestamp
                    )
                    LazyVStack(alignment: .leading, spacing: 15) {
                        ForEach(visible) { utterance in
                            TranscriptSpeakerRow(
                                speaker: utterance.speaker,
                                text: utterance.displayText,
                                elapsed: utterance.timestamp.timeIntervalSince(anchor ?? utterance.timestamp)
                            )
                            .id(utterance.id)
                        }

                        if !isSearching {
                            if !volatileYouText.isEmpty {
                                InterimRow(speaker: .you, text: volatileYouText)
                                    .id("volatile-you")
                            }

                            if !volatileThemText.isEmpty {
                                InterimRow(speaker: .them, text: volatileThemText)
                                    .id("volatile-them")
                            }
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onChange(of: utterances.count) {
                guard !isSearching, autoScrollEnabled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    if let last = utterances.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: volatileYouText) {
                guard !isSearching, autoScrollEnabled else { return }
                proxy.scrollTo("volatile-you", anchor: .bottom)
            }
            .onChange(of: volatileThemText) {
                guard !isSearching, autoScrollEnabled else { return }
                proxy.scrollTo("volatile-them", anchor: .bottom)
            }
            .onChange(of: searchText) {
                if searchText.isEmpty, autoScrollEnabled, let last = utterances.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !autoScrollEnabled {
                    Button {
                        autoScrollEnabled = true
                        if let last = utterances.last {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white, LoreTheme.Accent.blue)
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Resume auto-scroll")
                    .padding(12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
                }
            }
        }
    }
}

// MARK: - Elapsed stamps (#63)

/// Elapsed-from-start stamp for transcript rows: mm:ss below one hour,
/// h:mm:ss from there. Visual only — the copy paths keep absolute HH:MM:SS,
/// and the markdown mirror keeps its own relative format
/// (`MarkdownMeetingWriter.formatRelativeTimestamp`). Negatives (clock skew,
/// legacy data) clamp to 00:00.
enum ElapsedStamp {
    static func label(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 3600
            ? String(format: "%02d:%02d", total / 60, total % 60)
            : String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// The anchor both renderers stamp against: the recorded start when
    /// known, else the first utterance's timestamp (legacy sessions without
    /// a stored start; the live view after stop).
    static func anchor(startedAt: Date?, firstTimestamp: Date?) -> Date? {
        startedAt ?? firstTimestamp
    }
}

// MARK: - Rows

/// Fixed leading column width for the elapsed stamp so speaker labels stay
/// aligned across finalized and interim rows (#57).
private let timestampColumnWidth: CGFloat = 54

/// Finalized utterance: elapsed mono stamp + 64px speaker label + body text
/// (MREC-11, #57, #63). Shared by the live view and the review transcript;
/// render-only.
struct TranscriptSpeakerRow: View {
    let speaker: Speaker
    let text: String
    /// Seconds since recording start; the formatter clamps negatives.
    let elapsed: TimeInterval

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(ElapsedStamp.label(elapsed))
                .font(LoreTheme.Typography.mono(10.5))
                .foregroundStyle(LoreTheme.TextColor.muted)
                .frame(width: timestampColumnWidth, alignment: .leading)
                .padding(.top, 2)
            LoreSpeakerRow(speaker: speaker) {
                Text(text)
                    .font(LoreTheme.Typography.body)
                    .lineSpacing(4)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Volatile partial (MREC-12): row dimmed to .72 with a blinking blue caret.
/// The caret blinks step-end at the token duration via a periodic timeline
/// (no animation state); under Reduce Motion it renders statically without
/// the timer. The row is replaced by a finalized `TranscriptSpeakerRow`
/// when the segment lands.
private struct InterimRow: View {
    let speaker: Speaker
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let halfBlink = LoreTheme.Motion.blinkDuration / 2

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Empty stamp slot: keeps the speaker label column aligned with
            // finalized rows; the stamp lands when the segment finalizes.
            Color.clear.frame(width: timestampColumnWidth, height: 1)
            LoreSpeakerRow(speaker: speaker) {
                if reduceMotion {
                    interimText(caretOn: true)
                } else {
                    TimelineView(.periodic(from: .now, by: Self.halfBlink)) { context in
                        let phase = Int(context.date.timeIntervalSinceReferenceDate / Self.halfBlink)
                        interimText(caretOn: phase % 2 == 0)
                    }
                }
            }
        }
        .opacity(0.72)
    }

    private func interimText(caretOn: Bool) -> some View {
        (Text(text)
            + Text(" ")
            + Text("\u{258D}") // ▍ inline caret block, wraps with the text
                .foregroundStyle(caretOn ? LoreTheme.Accent.blue : Color.clear))
            .font(LoreTheme.Typography.body)
            .lineSpacing(4)
            .foregroundStyle(LoreTheme.TextColor.primary)
    }
}
