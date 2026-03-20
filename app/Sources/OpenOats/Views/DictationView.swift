import SwiftUI

struct DictationView: View {
    @Bindable var settings: AppSettings
    @Environment(AppCoordinator.self) private var coordinator

    @State private var hoveredEntryID: UUID?

    private var dictation: DictationCoordinator {
        coordinator.dictationCoordinator
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusBar
            Divider()
            historyList
            Divider()
            promptEditor
        }
        .frame(minWidth: 380, maxWidth: 600, minHeight: 500)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Dictation")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Toggle("Enabled", isOn: $settings.dictationEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
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
                Text("Hold Fn to talk")
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
                    Text("Locked — Fn to paste, Esc to discard")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                } else {
                    Text("Recording... Space to lock")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                }
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

    // MARK: - History

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
                    Text("Hold Fn and speak to get started")
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
                        Text("Audio saved — not yet transcribed")
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
                        Text("cleaned by GPT-5.3")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                    }
                }
            }

            Spacer()

            if hoveredEntryID == entry.id {
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
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(hoveredEntryID == entry.id ? Color.primary.opacity(0.03) : Color.clear)
        .onHover { isHovered in
            hoveredEntryID = isHovered ? entry.id : nil
        }
    }

    private func durationString(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%.0fm%02.0fs", seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - Prompt Editor

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Cleanup toggle + model badge
            HStack {
                Toggle("GPT-5.3 Cleanup", isOn: $settings.dictationCleanupEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))

                Spacer()

                if settings.dictationCleanupEnabled && settings.openaiApiKey.isEmpty {
                    Text("API key required")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }

            // API Key
            if settings.dictationCleanupEnabled {
                SecureField("OpenAI API Key", text: $settings.openaiApiKey)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                // Prompt
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

            HStack(spacing: 12) {
                Text("Fn = hold to talk")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                Text("Space = lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                Text("Esc = discard")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                Text("⌃⌘V = re-paste")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func timeString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}
