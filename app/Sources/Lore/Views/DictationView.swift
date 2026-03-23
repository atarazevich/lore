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

    @State private var selectedTab: DictationTab = .history
    @State private var searchText: String = ""

    private var dictation: DictationCoordinator {
        coordinator.dictationCoordinator
    }

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
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Lore")
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
                        Text(text)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
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

    // MARK: - Helpers

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt
    }()

    private func timeString(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}
