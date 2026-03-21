import SwiftUI

enum DictationTab: String, CaseIterable {
    case history = "History"
    case settings = "Settings"
}

struct DictationView: View {
    @Bindable var settings: AppSettings
    @Environment(AppCoordinator.self) private var coordinator

    @State private var hoveredEntryID: UUID?
    @State private var selectedTab: DictationTab = .history

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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(dictation.history.entries) { entry in
                            historyRow(entry)
                            Divider().padding(.leading, 16)
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
                    if let text = entry.finalText {
                        Text(text)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    if entry.status == .cleaned {
                        Text("cleaned")
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
                if let text = entry.finalText {
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

                // Retroactive cleanup button for transcribed entries
                if entry.rawText != nil {
                    Menu {
                        ForEach(settings.cleanupModes.filter { !$0.isRawPaste }) { mode in
                            Button(mode.name) {
                                Task {
                                    await dictation.cleanupHistoryEntry(entryID: entry.id, mode: mode)
                                }
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
            .opacity(hoveredEntryID == entry.id ? 1.0 : 0.4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(hoveredEntryID == entry.id ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredEntryID = isHovered ? entry.id : nil
            }
        }
    }

    private func durationString(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%.0fm%02.0fs", seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
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

                // Cleanup Prompt (shown when cleanup or translation is enabled)
                if settings.cleanupByDefault || settings.translationByDefault {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CLEANUP PROMPT")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .tracking(1.5)

                        TextEditor(text: $settings.dictationCleanupPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 60)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color.primary.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.06))
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

                Divider()

                hotkeyCheatSheet

                Spacer(minLength: 8)

                // Version
                Text("Lore v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
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
        }
        .font(.system(size: 10))
        .foregroundStyle(.quaternary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func timeString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}
