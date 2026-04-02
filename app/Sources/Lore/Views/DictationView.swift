import SwiftUI

enum DictationTab: String, CaseIterable {
    case history = "History"
    case settings = "Settings"
}

private struct HistoryDayGroup: Identifiable {
    let day: Date
    let label: String
    let entries: [DictationHistoryEntry]
    var id: Date { day }
}

struct DictationView: View {
    @Bindable var settings: AppSettings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(DictationCoordinator.self) private var dictation

    @State private var selectedTab: DictationTab = .history
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var searchKeyMonitor: Any?
    @State private var vocabFeedbackEntryID: UUID?
    @State private var vocabFeedbackText: String?
    @State private var editingEntryID: UUID?
    @State private var editingText: String = ""
    @State private var editingOriginalText: String = ""
    @FocusState private var isEditorFocused: Bool
    @State private var blurMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusBar
            Divider()
            tabBar
            Divider()

            switch selectedTab {
            case .history:
                historyTab
            case .settings:
                settingsTab
            }
        }
        .frame(minWidth: 380, maxWidth: 600, minHeight: 500)
        .background(.ultraThinMaterial)
        .onAppear {
            installSearchKeyMonitor()
            installBlurMonitor()
        }
        .onDisappear {
            removeSearchKeyMonitor()
            removeBlurMonitor()
        }
        .onChange(of: dictation.state) { _, newState in
            // Force-cancel edit when dictation starts recording
            if newState == .recording && editingEntryID != nil {
                cancelEdit()
            }
        }
        .onChange(of: selectedTab) { _, _ in
            if editingEntryID != nil {
                if settings.autoSubmitCorrections {
                    commitEdit()
                } else {
                    cancelEdit()
                }
            }
        }
        .onChange(of: isEditorFocused) { _, focused in
            // Primary auto-submit trigger (more reliable than NSEvent monitor alone)
            if !focused && editingEntryID != nil && settings.autoSubmitCorrections {
                // Defer slightly to avoid conflicts with cancel/commit already in progress
                DispatchQueue.main.async {
                    if editingEntryID != nil {
                        commitEdit()
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Dictation")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            switch dictation.state {
            case .idle:
                Image(systemName: "mic")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("Hold \(settings.hotkeyKey.displayName) to talk")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                if coordinator.hotkeyManager.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text("Locked \u{2014} \(settings.hotkeyKey.displayName) to paste, Esc to discard")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                } else {
                    Text("Recording... Space to lock")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                }
            case .loadingModel:
                ProgressView()
                    .controlSize(.mini)
                Text("Downloading model...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .processing:
                ProgressView()
                    .controlSize(.mini)
                Text("Processing...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text("Done")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let error = dictation.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            if !dictation.history.entries.isEmpty {
                Text("\(dictation.history.entries.count) entries")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(dictation.state == .recording ? Color.red.opacity(0.05) : Color.clear)
        .animation(.easeInOut(duration: 0.2), value: dictation.state)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DictationTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.primary.opacity(0.05) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - History Tab

    private var historyTab: some View {
        VStack(spacing: 0) {
            historyList
            Divider()
            hotkeyCheatSheet
        }
    }

    // MARK: - History List

    private var filteredEntries: [DictationHistoryEntry] {
        let entries = dictation.history.entries
        guard !searchText.isEmpty else { return entries }
        return entries.filter { entry in
            let raw = entry.rawText ?? ""
            let cleaned = entry.cleanedText ?? ""
            return raw.localizedCaseInsensitiveContains(searchText)
                || cleaned.localizedCaseInsensitiveContains(searchText)
        }
    }

    private static let dayLabelFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt
    }()

    private var groupedEntries: [HistoryDayGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        var groups: [(day: Date, entries: [DictationHistoryEntry])] = []
        var currentDay: Date?
        var currentEntries: [DictationHistoryEntry] = []

        for entry in filteredEntries {
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
                label = Self.dayLabelFormatter.string(from: day)
            }
            return HistoryDayGroup(day: day, label: label, entries: entries)
        }
    }

    private var historyList: some View {
        Group {
            if dictation.history.entries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "text.bubble")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text("No dictation history yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text("Hold \(settings.hotkeyKey.displayName) and speak to get started")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    // Search field
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        TextField("Search history...", text: $searchText)
                            .font(.system(size: 12))
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.03))

                    Divider()

                    if filteredEntries.isEmpty && !searchText.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Text("No results for \u{201C}\(searchText)\u{201D}")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                                ForEach(groupedEntries) { group in
                                    Section {
                                        ForEach(group.entries) { entry in
                                            historyRow(entry)
                                            Divider().padding(.leading, 16)
                                        }
                                    } header: {
                                        HStack {
                                            Text(group.label)
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                                .textCase(.uppercase)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 4)
                                        .background(.ultraThinMaterial)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ entry: DictationHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 2) {
                Text(timeString(entry.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(durationString(entry.durationSeconds))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
            .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                switch entry.status {
                case .audioSaved:
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("Audio saved \u{2014} not yet transcribed")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                case .failed:
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                        Text(entry.errorMessage ?? "Transcription failed")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                case .transcribed, .cleaned:
                    if let text = entry.displayText {
                        VStack(alignment: .leading, spacing: 2) {
                            if editingEntryID == entry.id {
                                // Edit mode
                                VStack(alignment: .leading, spacing: 4) {
                                    TextEditor(text: $editingText)
                                        .font(.system(size: 12))
                                        .scrollContentBackground(.hidden)
                                        .frame(maxHeight: 200)
                                        .padding(4)
                                        .background(Color.accentColor.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
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

                                    if !settings.autoSubmitCorrections {
                                        HStack(spacing: 6) {
                                            Button {
                                                commitEdit()
                                            } label: {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(.green)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Save changes")

                                            Button {
                                                cancelEdit()
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Discard changes")
                                        }
                                    }
                                }
                            } else {
                                // Read mode — double-click to edit
                                highlightedText(text)
                                    .font(.system(size: 12))
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        startEditing(entry: entry, text: text)
                                    }
                            }

                            if vocabFeedbackEntryID == entry.id, let feedback = vocabFeedbackText {
                                Text(feedback)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.green)
                                    .transition(.opacity)
                            }
                        }
                    }
                    if entry.hasBothVersions {
                        Text(entry.activeVersion == .cleaned ? "Cleaned" : "Original")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                // Retry button for failed or audio-only entries
                if entry.status == .failed || entry.status == .audioSaved {
                    Button {
                        Task {
                            await dictation.retryTranscription(entryID: entry.id)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Retry transcription")
                }

                // Copy button for transcribed entries
                if let text = entry.displayText {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")
                }

                // Toggle between raw and cleaned versions
                if entry.hasBothVersions {
                    Button {
                        var updated = entry
                        updated.activeVersion = entry.activeVersion == .cleaned ? .raw : .cleaned
                        dictation.history.update(updated)
                    } label: {
                        Image(systemName: entry.activeVersion == .cleaned ? "arrow.uturn.backward" : "sparkles")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(entry.activeVersion == .cleaned ? "Show original" : "Show cleaned")
                }

                // Retroactive cleanup button for transcribed entries
                if entry.rawText != nil {
                    Menu {
                        Button("Clean up") {
                            Task {
                                let mode = CleanupMode(name: "Cleanup", prompt: settings.activeCleanupPrompt)
                                await dictation.cleanupHistoryEntry(entryID: entry.id, mode: mode)
                            }
                        }
                        Button("Translate") {
                            Task {
                                let prompt = settings.activeCleanupPrompt + CleanupMode.translateSuffix
                                let mode = CleanupMode(name: "Translate", prompt: prompt)
                                await dictation.cleanupHistoryEntry(entryID: entry.id, mode: mode)
                            }
                        }
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                    .help("Clean up with...")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func durationString(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%.0fm%02.0fs", seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Cleanup toggle
                Toggle("Cleanup by default", isOn: Binding(
                    get: { settings.cleanupByDefault },
                    set: { newValue in
                        settings.cleanupByDefault = newValue
                        if !newValue {
                            settings.translationByDefault = false
                        }
                    }
                ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12))

                // Translation toggle
                Toggle("Translation by default", isOn: Binding(
                    get: { settings.translationByDefault },
                    set: { newValue in
                        settings.translationByDefault = newValue
                        if newValue {
                            settings.cleanupByDefault = true
                        }
                    }
                ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12))

                if settings.translationByDefault {
                    Text("Translation includes cleanup automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Vocabulary learning toggle
                Toggle("Learn vocabulary from corrections", isOn: $settings.learnVocabularyFromCorrections)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12))

                // Auto-submit corrections toggle
                Toggle("Auto-submit corrections (experimental)", isOn: $settings.autoSubmitCorrections)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12))

                // Phonetic threshold slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Phonetic threshold")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f", settings.correctionPhoneticThreshold))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Slider(value: $settings.correctionPhoneticThreshold, in: 0.0...1.0, step: 0.05)
                        .controlSize(.mini)
                }

                // API key warning
                if (settings.cleanupByDefault || settings.translationByDefault)
                    && settings.openaiApiKey.isEmpty {
                    Text("OpenAI API key required")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                // API Key
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenAI API Key")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    SecureField("sk-...", text: $settings.openaiApiKey)
                        .font(.system(size: 11, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }

                // Cleanup Prompt (always visible — used by C/T hotkeys even when not default)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cleanup Prompt")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Picker("Preset", selection: $settings.cleanupPreset) {
                        ForEach(CleanupPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .font(.system(size: 12))

                    if settings.cleanupPreset == .custom {
                        TextEditor(text: $settings.customCleanupPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 80)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.1))
                            )
                    } else {
                        Text(settings.activeCleanupPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 80)
                            .padding(6)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.1))
                            )
                    }
                }

                // Learned vocabulary log
                if !settings.learnedWords.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Learned vocabulary")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 0) {
                            ForEach(settings.learnedWords.prefix(20)) { word in
                                HStack(spacing: 6) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(word.correction)")
                                            .font(.system(size: 11, weight: .medium))
                                        Text("was: \(word.original)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Text(word.date, style: .date)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.quaternary)
                                    Button {
                                        settings.removeLearnedWordAndVocabulary(id: word.id)
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove from vocabulary")
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                            }
                        }
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // Hotkey picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hotkey")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("Hotkey", selection: $settings.hotkeyKey) {
                        ForEach(HotkeyKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                    .font(.system(size: 12))
                }

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        Divider()
        hotkeyCheatSheet
        } // VStack
    }

    // MARK: - Hotkey Cheat Sheet

    private var hotkeyLabel: String {
        switch settings.hotkeyKey {
        case .fn: "Fn"
        case .rightOption: "R⌥"
        }
    }

    private var hotkeyCheatSheet: some View {
        HStack(spacing: 12) {
            Text("\(hotkeyLabel) = hold to talk")
            Text("Space = lock")
            Text("C = cleanup")
            Text("T = translate")
            Text("Esc = discard")
            Spacer()
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        }
        .font(.system(size: 10))
        .foregroundStyle(.quaternary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
        let savedEntryID = entryID
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

        // Run diff for vocabulary learning
        if settings.learnVocabularyFromCorrections {
            learnFromDiff(original: originalText, edited: newText, entryID: savedEntryID)
        }
    }

    private func learnFromDiff(original: String, edited: String, entryID: UUID) {
        guard let islands = TextDiff.findIslands(original: original, edited: edited) else { return }

        var addedTerms: [String] = []
        let threshold = settings.correctionPhoneticThreshold

        for island in islands {
            let classification = PhoneticSimilarity.classifyIsland(
                originalWords: island.originalWords,
                editedWords: island.editedWords,
                baseThreshold: threshold
            )
            if classification == .misrecognition {
                let correction = island.editedWords.joined(separator: " ")
                let original = island.originalWords.joined(separator: " ")
                if addToVocabulary(correction: correction, original: original) {
                    addedTerms.append(correction)
                }
            }
        }

        if !addedTerms.isEmpty {
            let message = "Added '\(addedTerms.joined(separator: "', '"))' to vocabulary"
            showVocabFeedback(for: entryID, message: message)
        }
    }

    private func addToVocabulary(correction: String, original: String) -> Bool {
        settings.addToVocabulary(correction: correction, original: original)
    }

    private func showVocabFeedback(for entryID: UUID, message: String) {
        withAnimation(.easeIn(duration: 0.2)) {
            vocabFeedbackEntryID = entryID
            vocabFeedbackText = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeOut(duration: 0.3)) {
                if vocabFeedbackEntryID == entryID {
                    vocabFeedbackEntryID = nil
                    vocabFeedbackText = nil
                }
            }
        }
    }

    // MARK: - Blur Monitor (auto-submit mode)

    private func installBlurMonitor() {
        blurMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard settings.autoSubmitCorrections, editingEntryID != nil else { return event }
            // If the click is outside our editing area, commit the edit
            // We check by scheduling on next runloop — if focus was lost, commit
            DispatchQueue.main.async {
                if !isEditorFocused && editingEntryID != nil {
                    commitEdit()
                }
            }
            return event
        }
    }

    private func removeBlurMonitor() {
        if let monitor = blurMonitor {
            NSEvent.removeMonitor(monitor)
            blurMonitor = nil
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
        searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard selectedTab == .history, editingEntryID == nil else { return event }

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
