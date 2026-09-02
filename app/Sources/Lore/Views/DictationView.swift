import SwiftUI

private struct HistoryDayGroup: Identifiable {
    let day: Date
    let label: String
    let entries: [DictationHistoryEntry]
    var id: Date { day }
}

/// Memoized filter+group projection (#51): recomputed only when the history
/// mutates (`DictationHistory.revision`), the search text changes, or the
/// calendar day flips — never on unrelated body evaluations. A class box so
/// mutating the cache during `body` cannot invalidate the view.
@MainActor
private final class HistoryProjectionCache {
    private var key: (revision: Int, searchText: String, today: Date)?
    private var filtered: [DictationHistoryEntry] = []
    private var groups: [HistoryDayGroup] = []

    private static let dayLabelFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt
    }()

    func projection(
        entries: [DictationHistoryEntry], revision: Int, searchText: String
    ) -> (filtered: [DictationHistoryEntry], groups: [HistoryDayGroup]) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let newKey = (revision, searchText, today)
        if key == nil || key! != newKey {
            filtered = Self.filter(entries, searchText: searchText)
            groups = Self.group(filtered, calendar: calendar, today: today)
            key = newKey
        }
        return (filtered, groups)
    }

    private static func filter(
        _ entries: [DictationHistoryEntry], searchText: String
    ) -> [DictationHistoryEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { entry in
            let raw = entry.rawText ?? ""
            let cleaned = entry.cleanedText ?? ""
            return raw.localizedCaseInsensitiveContains(searchText)
                || cleaned.localizedCaseInsensitiveContains(searchText)
        }
    }

    private static func group(
        _ entries: [DictationHistoryEntry], calendar: Calendar, today: Date
    ) -> [HistoryDayGroup] {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        var groups: [(day: Date, entries: [DictationHistoryEntry])] = []
        var currentDay: Date?
        var currentEntries: [DictationHistoryEntry] = []

        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            if day != currentDay {
                if let d = currentDay {
                    groups.append((d, currentEntries))
                }
                currentDay = day
                currentEntries = [entry]
            } else {
                currentEntries.append(entry)
            }
        }
        if let d = currentDay {
            groups.append((d, currentEntries))
        }

        return groups.map { (day, entries) in
            let label: String
            if day == today {
                label = "Today"
            } else if day == yesterday {
                label = "Yesterday"
            } else {
                label = dayLabelFormatter.string(from: day)
            }
            return HistoryDayGroup(day: day, label: label, entries: entries)
        }
    }
}

/// Which row popover is open — one at a time across the whole list (DIC-35/36).
private enum RowPopover: Equatable {
    case cleanup(UUID)
    case translate(UUID)
}

struct DictationView: View {
    @Bindable var settings: AppSettings
    /// False while the unified shell shows another destination. Gates the
    /// local key monitors so the hidden dictation search does not intercept
    /// keystrokes meant for other destinations.
    var isActiveInShell: Bool = true
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(DictationCoordinator.self) private var dictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var searchKeyMonitor: Any?
    /// Transient per-row feedback line for red transform failures (#50).
    @State private var rowFeedback: RowFeedback?
    @State private var editingEntryID: UUID?
    @State private var editingText: String = ""
    @State private var editingOriginalText: String = ""
    @FocusState private var isEditorFocused: Bool
    @State private var activePopover: RowPopover?
    @State private var projectionCache = HistoryProjectionCache()

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            LoreDivider()
            historyTab
        }
        .onDisappear {
            removeSearchKeyMonitor()
        }
        .onChange(of: isActiveInShell, initial: true) { _, isActive in
            if isActive {
                installSearchKeyMonitor()
            } else {
                removeSearchKeyMonitor()
                // The hidden view must not keep first responder or an open edit.
                isSearchFocused = false
                if editingEntryID != nil {
                    cancelEdit()
                }
            }
        }
        .onChange(of: dictation.state) { _, newState in
            // Force-cancel edit when dictation starts recording
            if newState == .recording && editingEntryID != nil {
                cancelEdit()
            }
        }
    }

    // MARK: - Status Strip (DIC-21…24)

    private var statusStrip: some View {
        HStack(spacing: 10) {
            switch dictation.state {
            case .idle:
                Image(systemName: "mic")
                    .font(.system(size: 12))
                    .foregroundStyle(LoreTheme.TextColor.sidebarInactive)
                Text("Hold \(settings.hotkeyKey.displayName) to talk")
                    .font(LoreTheme.Typography.body)
                    .foregroundStyle(LoreTheme.TextColor.muted)
            case .recording:
                LorePulsingDot()
                if coordinator.hotkeyManager.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LoreTheme.Accent.red)
                    Text("Locked \u{2014} " + DictationIndicatorView.lockedWaysOut(
                        talkKey: settings.hotkeyKey.shortName
                    ))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LoreTheme.Accent.red)
                } else {
                    // Only advertise Space-lock while that modifier is enabled.
                    Text(settings.modifierLockEnabled
                            ? "Recording... Space to lock" : "Recording...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LoreTheme.Accent.red)
                }
            case .loadingModel:
                ProgressView()
                    .controlSize(.mini)
                Text("Downloading model...")
                    .font(LoreTheme.Typography.body)
                    .foregroundStyle(LoreTheme.TextColor.muted)
            case .processing:
                ProgressView()
                    .controlSize(.mini)
                Text("Processing...")
                    .font(LoreTheme.Typography.body)
                    .foregroundStyle(LoreTheme.TextColor.muted)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(LoreTheme.Accent.green)
                Text("Done")
                    .font(LoreTheme.Typography.body)
                    .foregroundStyle(LoreTheme.TextColor.muted)
            }

            Spacer()

            if let error = dictation.lastError {
                Text(error.sentence)
                    .font(.system(size: 11))
                    .foregroundStyle(LoreTheme.Accent.red)
                    .lineLimit(1)
            }

            // A history entry that silently failed to persist must be
            // visible — cleared automatically by the next successful save.
            if let saveError = dictation.history.lastSaveError {
                Text(saveError)
                    .font(.system(size: 11))
                    .foregroundStyle(LoreTheme.Accent.red)
                    .lineLimit(1)
            }

            if !dictation.history.entries.isEmpty {
                // Honest counter (#51): total when idle (the cap is gone),
                // "N of M" matches while searching. Comma-grouped (#220) —
                // pinned to the same `en_US` grouping the Stats pane uses
                // (`DictationActivityFormat.groupedNumber`, review — A6), so
                // this strip and that pane never disagree on how a count reads.
                Text(searchText.isEmpty
                    ? "\(DictationActivityFormat.groupedNumber(dictation.history.entries.count)) entries"
                    : "\(DictationActivityFormat.groupedNumber(historyProjection.filtered.count)) of "
                        + "\(DictationActivityFormat.groupedNumber(dictation.history.entries.count))")
                    .font(LoreTheme.Typography.mono(11.5))
                    .foregroundStyle(LoreTheme.TextColor.muted)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 11)
        .background(
            dictation.state == .recording
                ? LoreTheme.Accent.red.opacity(0.08)
                : Color.white.opacity(0.02)
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.2),
            value: dictation.state
        )
    }

    // MARK: - History (settings moved to the unified Settings destination in
    // Stage D; Activity moved to the standalone Stats destination, #220)

    private var historyTab: some View {
        VStack(spacing: 0) {
            historyList
            LoreDivider()
            hotkeyCheatSheet
        }
    }

    // MARK: - History List

    /// Reads `entries` and `revision` from the observable history so body
    /// re-evaluates on mutations; the heavy work is memoized in the cache.
    private var historyProjection: (filtered: [DictationHistoryEntry], groups: [HistoryDayGroup]) {
        projectionCache.projection(
            entries: dictation.history.entries,
            revision: dictation.history.revision,
            searchText: searchText
        )
    }

    private var historyList: some View {
        Group {
            if dictation.history.entries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "text.bubble")
                        .font(.system(size: 28))
                        .foregroundStyle(LoreTheme.TextColor.faint)
                    Text("No dictation history yet")
                        .font(LoreTheme.Typography.body)
                        .foregroundStyle(LoreTheme.TextColor.muted)
                    Text("Hold \(settings.hotkeyKey.displayName) and speak to get started")
                        .font(LoreTheme.Typography.meta)
                        .foregroundStyle(LoreTheme.TextColor.faint)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    searchRow
                    LoreDivider()

                    if historyProjection.filtered.isEmpty && !searchText.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Text("Nothing matches \u{201C}\(searchText)\u{201D}")
                                .font(LoreTheme.Typography.body)
                                .foregroundStyle(LoreTheme.TextColor.muted)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                                ForEach(historyProjection.groups) { group in
                                    Section {
                                        ForEach(group.entries) { entry in
                                            historyRow(entry)
                                            LoreDivider()
                                        }
                                    } header: {
                                        dayHeader(group.label)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Search Row (DIC-28)

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(LoreTheme.TextColor.sidebarInactive)
            TextField("Search history\u{2026}", text: $searchText)
                .font(LoreTheme.Typography.body)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LoreTheme.TextColor.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 8)
    }

    // MARK: - Day Header (DIC-26)

    private func dayHeader(_ label: String) -> some View {
        LoreSectionLabel(text: label, size: 10.5, mono: true, trackingEm: 0.09)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.vertical, 6)
            .background(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.82))
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { LoreDivider() }
    }

    // MARK: - History Row (DIC-27)

    private func historyRow(_ entry: DictationHistoryEntry) -> some View {
        let popoverOpen = activePopover == .cleanup(entry.id)
            || activePopover == .translate(entry.id)

        return HoverRevealRow(forceRevealed: popoverOpen) { revealed in
            HStack(alignment: .top, spacing: 18) {
                // 56px centered mono time + duration column
                VStack(spacing: 3) {
                    Text(timeString(entry.timestamp))
                        .font(LoreTheme.Typography.mono(12.5, weight: .semibold))
                        .foregroundStyle(LoreTheme.TextColor.primary)
                    Text(durationString(entry.durationSeconds))
                        .font(LoreTheme.Typography.mono(11))
                        .foregroundStyle(LoreTheme.TextColor.muted)
                }
                .frame(width: 56)
                .padding(.top, 1)

                rowContent(entry)
                    .frame(maxWidth: .infinity, alignment: .leading)

                rowActions(entry, revealed: revealed)
            }
            .padding(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 26))
        }
    }

    @ViewBuilder
    private func rowContent(_ entry: DictationHistoryEntry) -> some View {
        switch entry.status {
        case .audioSaved:
            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                Text("Audio saved \u{2014} not yet transcribed")
                    .font(LoreTheme.Typography.body)
            }
            .foregroundStyle(LoreTheme.TextColor.muted)
            .padding(.top, 1)
        case .failed:
            HStack(spacing: 9) {
                Text("\u{26A0}")
                    .font(.system(size: 13))
                Text(entry.errorMessage ?? "Transcription failed")
                    .font(LoreTheme.Typography.body)
            }
            .foregroundStyle(LoreTheme.Accent.red)
            .padding(.top, 1)
        case .transcribed, .cleaned:
            VStack(alignment: .leading, spacing: 5) {
                if let text = entry.displayText {
                    if editingEntryID == entry.id {
                        editControls
                    } else {
                        // Read mode — double-click to edit (DIC-40)
                        highlightedText(text)
                            .font(LoreTheme.Typography.body)
                            .foregroundStyle(LoreTheme.TextColor.primary)
                            .lineSpacing(4) // ≈ line-height 1.55 at 13px
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                startEditing(entry: entry, text: text)
                            }
                    }
                }

                if let feedback = rowFeedback, feedback.entryID == entry.id {
                    Text(feedback.text)
                        .font(.system(size: 11))
                        .foregroundStyle(feedback.color)
                        .transition(.opacity)
                }

                metaLine(entry)
            }
        }
    }

    /// Inline editor block (DIC-40/41) — behavior unchanged, restyled to tokens.
    private var editControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $editingText)
                .font(LoreTheme.Typography.body)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 200)
                .padding(4)
                .background(LoreTheme.Accent.blue.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: LoreTheme.Radius.button))
                .overlay(
                    RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                        .stroke(LoreTheme.Accent.blue.opacity(0.3), lineWidth: 1)
                )
                .focused($isEditorFocused)
                .onExitCommand { cancelEdit() }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        commitEdit()
                        return .handled
                    }
                    return .ignored
                }

            HStack(spacing: 6) {
                Button {
                    commitEdit()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LoreTheme.Accent.green)
                }
                .buttonStyle(.plain)
                .help("Save changes")

                Button {
                    cancelEdit()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LoreTheme.TextColor.muted)
                }
                .buttonStyle(.plain)
                .help("Discard changes")
            }
        }
    }

    /// "✦ cleaned · <method>" / "✦ translated → <lang>" under the text
    /// (DIC-37); "original" when the raw version is active (keeps the current
    /// two-version indicator semantics).
    @ViewBuilder
    private func metaLine(_ entry: DictationHistoryEntry) -> some View {
        if entry.hasBothVersions {
            Group {
                if entry.activeVersion == .cleaned {
                    Text("\u{2726} ").foregroundStyle(LoreTheme.Accent.amber)
                        + Text(cleanedMetaLabel(entry)).foregroundStyle(LoreTheme.TextColor.muted)
                } else {
                    Text("original").foregroundStyle(LoreTheme.TextColor.muted)
                }
            }
            .font(LoreTheme.Typography.mono(11))
        }
    }

    /// Single source of truth for the cleaned meta text: the new key fields
    /// first (tolerant — an unknown key renders verbatim), legacy entries that
    /// only carry `cleanupModeName` fall back to plain "cleaned".
    private func cleanedMetaLabel(_ entry: DictationHistoryEntry) -> String {
        if let key = entry.translatedToLanguage {
            return "translated \u{2192} \(TranslationLanguage(rawValue: key)?.displayName ?? key)"
        }
        if let key = entry.cleanupMethodName {
            return "cleaned \u{00B7} \(CleanupMethod(rawValue: key)?.displayName ?? key)"
        }
        return "cleaned"
    }

    // MARK: - Row Actions (DIC-33…36, 44)

    @ViewBuilder
    private func rowActions(_ entry: DictationHistoryEntry, revealed: Bool) -> some View {
        // Retry requires the audio to still exist — after retention pruning
        // (#52) a failed/audio-only entry may have lost its file, and a
        // button that can only log "no audio" is a lie. Hidden, not disabled.
        if (entry.status == .failed || entry.status == .audioSaved) && entry.hasAudio {
            // Retry stays visible without hover, like the design's error row.
            LoreIconButton(
                systemName: "arrow.clockwise",
                label: "Retry transcription",
                tint: LoreTheme.Accent.red,
                background: LoreTheme.Accent.red.opacity(0.12)
            ) {
                Task {
                    await dictation.retryTranscription(entryID: entry.id)
                }
            }
            .help("Retry transcription")
        } else if entry.displayText != nil {
            HStack(alignment: .top, spacing: 6) {
                copyButton(entry)
                if entry.rawText != nil {
                    cleanupButton(entry)
                    translateButton(entry)
                }
                if entry.hasBothVersions {
                    versionToggleButton(entry)
                }
            }
            .opacity(revealed ? 1 : 0)
            .allowsHitTesting(revealed)
            .animation(
                reduceMotion ? nil : .easeOut(duration: LoreTheme.Motion.hoverDuration),
                value: revealed
            )
        }
    }

    /// Copy with green ✓ feedback for ~1.4s (DIC-34).
    private func copyButton(_ entry: DictationHistoryEntry) -> some View {
        LoreCopyButton {
            guard let text = entry.displayText else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func cleanupButton(_ entry: DictationHistoryEntry) -> some View {
        rowPopoverButton(
            systemName: "sparkles",
            label: "Clean up",
            popover: .cleanup(entry.id)
        ) {
            LorePickerPopover(
                header: "Cleanup method",
                items: CleanupMethod.allCases,
                width: 224,
                isActive: { $0.key == entry.cleanupMethodName },
                onSelect: { method in
                    activePopover = nil
                    Task {
                        if !(await dictation.cleanupHistoryEntry(entryID: entry.id, method: method)) {
                            showTransformFailure(for: entry.id, action: "Cleanup")
                        }
                    }
                },
                itemLabel: { method in
                    Text(method.glyph)
                        .font(.system(size: 12))
                        .foregroundStyle(LoreTheme.Accent.amber)
                        .frame(width: 15)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(method.displayName)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(LoreTheme.TextColor.primary)
                        Text(method.subtitle)
                            .font(LoreTheme.Typography.meta)
                            .foregroundStyle(LoreTheme.TextColor.muted)
                    }
                }
            )
        }
    }

    private func translateButton(_ entry: DictationHistoryEntry) -> some View {
        rowPopoverButton(
            systemName: "globe",
            label: "Translate",
            popover: .translate(entry.id)
        ) {
            LorePickerPopover(
                header: "Translate to",
                items: TranslationLanguage.allCases,
                width: 180,
                isActive: { $0.key == entry.translatedToLanguage },
                onSelect: { language in
                    activePopover = nil
                    Task {
                        if !(await dictation.translateHistoryEntry(entryID: entry.id, to: language)) {
                            showTransformFailure(for: entry.id, action: "Translation")
                        }
                    }
                },
                title: { $0.displayName }
            )
        }
    }

    /// Amber popover-anchor button shared by Clean up ✦ and Translate:
    /// amber-tinted fill while its popover is open, one popover at a time.
    private func rowPopoverButton<Content: View>(
        systemName: String,
        label: String,
        popover: RowPopover,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isOpen = activePopover == popover
        return LoreIconButton(
            systemName: systemName,
            label: label,
            tint: LoreTheme.Accent.amber,
            background: isOpen ? LoreTheme.Accent.amber.opacity(0.16)
                               : Color.white.opacity(0.07)
        ) {
            activePopover = isOpen ? nil : popover
        }
        .help("\(label)\u{2026}")
        .popover(
            isPresented: Binding(
                get: { activePopover == popover },
                set: { activePopover = $0 ? popover : nil }
            ),
            arrowEdge: .bottom,
            content: content
        )
    }

    /// Two-way raw ↔ cleaned toggle (DIC-38): ↺ when the cleaned version is
    /// shown, ✦ when the raw version is shown. Non-destructive.
    private func versionToggleButton(_ entry: DictationHistoryEntry) -> some View {
        let showingCleaned = entry.activeVersion == .cleaned
        return LoreIconButton(
            systemName: showingCleaned ? "arrow.uturn.backward" : "sparkles",
            label: showingCleaned ? "Show original" : "Show cleaned"
        ) {
            var updated = entry
            updated.activeVersion = showingCleaned ? .raw : .cleaned
            dictation.history.update(updated)
        }
        .help(showingCleaned ? "Show original" : "Show cleaned")
    }

    private func durationString(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        // Truncate both components so 119.6s is "1m 59s", never "1m 60s".
        let minutes = Int(seconds / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        return String(format: "%dm %02ds", minutes, secs)
    }

    // MARK: - Footer Kbd Bar (DIC-25)

    /// DIC-25 (dynamic since Stage D): the bar builds from the enabled
    /// modifiers — "{hotkey} hold to talk" first, "Esc cancel" last, the
    /// hints in between appear only while their Settings toggle is on.
    ///
    /// Fn+V and Fn+T say "Fn" literally whatever the talk key is (#226): they
    /// read the physical Fn flag off the event, so the chosen key's name there
    /// would be a hint the keyboard disagrees with. The pause chord is the
    /// other way round (#233) — it is the talk key that has to be held, so it
    /// is the talk key that is named, and it stands next to the lock because
    /// the two Space gestures are one pair, in the order they happen.
    private var hotkeyCheatSheet: some View {
        HStack(spacing: 16) {
            kbdHint(settings.hotkeyKey.shortName, "hold to talk")
            if settings.modifierLockEnabled {
                kbdHint("Space", "lock")
                kbdHint("\(settings.hotkeyKey.shortName)+Space", "pause")
            }
            if settings.modifierCleanupEnabled {
                kbdHint("Fn+V", "cleanup")
            }
            if settings.modifierTranslateEnabled {
                kbdHint("Fn+T", "translate")
            }
            kbdHint("Esc", "cancel")
            Spacer()
        }
        .font(LoreTheme.Typography.mono(11))
        .padding(.horizontal, 26)
        .padding(.vertical, 11)
    }

    private func kbdHint(_ key: String, _ what: String) -> Text {
        Text(key)
            .fontWeight(.semibold)
            .foregroundStyle(LoreTheme.TextColor.primary)
            + Text(" = \(what)")
            .foregroundStyle(LoreTheme.TextColor.muted)
    }

    // MARK: - Inline Editing

    private func startEditing(entry: DictationHistoryEntry, text: String) {
        // Commit any existing edit first
        if editingEntryID != nil {
            commitEdit()
        }
        // Clear search so the row doesn't disappear from filtered results after save
        searchText = ""
        editingEntryID = entry.id
        editingText = text
        editingOriginalText = text
        // Defer focus to next runloop so TextEditor is mounted
        DispatchQueue.main.async {
            isEditorFocused = true
        }
    }

    private func cancelEdit() {
        editingEntryID = nil
        editingText = ""
        editingOriginalText = ""
        isEditorFocused = false
    }

    private func commitEdit() {
        guard let entryID = editingEntryID else { return }
        let newText = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalText = editingOriginalText

        // Find the entry
        guard let entry = dictation.history.entries.first(where: { $0.id == entryID }) else {
            cancelEdit()
            return
        }

        // Exit edit mode first
        editingEntryID = nil
        editingText = ""
        editingOriginalText = ""
        isEditorFocused = false

        // If text didn't change, nothing to do
        guard newText != originalText else { return }

        // Update the entry text
        var updated = entry
        switch entry.activeVersion {
        case .raw: updated.rawText = newText
        case .cleaned: updated.cleanedText = newText
        }
        dictation.history.update(updated)
    }

    /// Red transient failure line for a retroactive transform (#50). The
    /// popover action stays retryable — re-open and re-select.
    private func showTransformFailure(for entryID: UUID, action: String) {
        let message = settings.openaiApiKey.isEmpty
            ? "\(action) failed \u{2014} no OpenAI API key in Settings"
            : "\(action) failed \u{2014} text unchanged"
        showRowFeedback(
            for: entryID, message: message,
            color: LoreTheme.Accent.red, duration: 4
        )
    }

    private struct RowFeedback: Equatable {
        let entryID: UUID
        let text: String
        let color: Color
    }

    private func showRowFeedback(
        for entryID: UUID, message: String, color: Color, duration: Double
    ) {
        let feedback = RowFeedback(entryID: entryID, text: message, color: color)
        withAnimation(.easeIn(duration: 0.2)) {
            rowFeedback = feedback
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation(.easeOut(duration: 0.3)) {
                if rowFeedback == feedback {
                    rowFeedback = nil
                }
            }
        }
    }

    // MARK: - Helpers

    /// Build a Text view with search matches highlighted in yellow.
    private func highlightedText(_ text: String) -> Text {
        guard !searchText.isEmpty else { return Text(text) }
        var result = Text("")
        var current = text.startIndex
        while let range = text.range(of: searchText, options: .caseInsensitive, range: current..<text.endIndex) {
            if current < range.lowerBound {
                result = result + Text(text[current..<range.lowerBound])
            }
            result = result + Text(text[range])
                .foregroundColor(.yellow)
                .bold()
            current = range.upperBound
        }
        if current < text.endIndex {
            result = result + Text(text[current..<text.endIndex])
        }
        return result
    }

    // MARK: - Search Key Monitor

    private func installSearchKeyMonitor() {
        guard searchKeyMonitor == nil else { return }
        searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard editingEntryID == nil else { return event }

            // While a row popover is open it owns the keyboard: Esc dismisses
            // it (consumed); other keys must not be captured into search.
            if activePopover != nil {
                if event.keyCode == 53 {
                    activePopover = nil
                    return nil
                }
                return event
            }

            // Escape → clear search
            if event.keyCode == 53 && !searchText.isEmpty {
                searchText = ""
                isSearchFocused = true  // Keep focus so next typing works
                return nil
            }

            // Typing while search is NOT focused → redirect to search field
            if !isSearchFocused,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let chars = event.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                isSearchFocused = true
                // Let the event through — TextField will receive it once focused
                // Use async to ensure focus takes effect before the event arrives
                DispatchQueue.main.async {
                    // Re-post the character so the now-focused TextField receives it
                    let charEvent = NSEvent.keyEvent(
                        with: .keyDown,
                        location: event.locationInWindow,
                        modifierFlags: event.modifierFlags,
                        timestamp: event.timestamp,
                        windowNumber: event.windowNumber,
                        context: nil,
                        characters: chars,
                        charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? chars,
                        isARepeat: event.isARepeat,
                        keyCode: event.keyCode
                    )
                    if let charEvent {
                        NSApp.sendEvent(charEvent)
                    }
                }
                return nil  // Consume the original event (we'll re-post it)
            }

            return event
        }
    }

    private func removeSearchKeyMonitor() {
        if let monitor = searchKeyMonitor {
            NSEvent.removeMonitor(monitor)
            searchKeyMonitor = nil
        }
    }

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt
    }()

    private func timeString(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}

// MARK: - Hover Reveal Row (#51)

/// Row wrapper owning its hover state: mousing over the list re-evaluates
/// only this row's body, not the whole DictationView (which previously ran
/// the O(n) filter/group work on every hover via view-level @State).
private struct HoverRevealRow<Content: View>: View {
    var forceRevealed: Bool
    @ViewBuilder var content: (Bool) -> Content
    @State private var isHovered = false

    var body: some View {
        content(isHovered || forceRevealed)
            .loreHoverFill(Color.white.opacity(0.035)) { isHovered = $0 }
    }
}

// MARK: - Cleanup Method Presentation (popover subtitle/glyph, view-only)

private extension CleanupMethod {
    /// Popover subtitle per the design.
    var subtitle: String {
        switch self {
        case .standard: "Remove fillers, fix punctuation"
        case .punctuationOnly: "Keep wording, add punctuation"
        case .formalTone: "Rewrite more formally"
        case .bulletPoints: "Condense into a list"
        }
    }

    /// Popover leading glyph per the design (\u{2726} \u{00B7} \u{00A7} \u{2261}).
    var glyph: String {
        switch self {
        case .standard: "\u{2726}"
        case .punctuationOnly: "\u{00B7}"
        case .formalTone: "\u{00A7}"
        case .bulletPoints: "\u{2261}"
        }
    }
}
