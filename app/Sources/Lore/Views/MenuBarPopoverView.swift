import SwiftUI

struct MenuBarPopoverView: View {
    let coordinator: AppCoordinator
    let settings: AppSettings
    let onShowMainWindow: () -> Void
    let onShowMeetings: () -> Void
    let onCheckForUpdates: () -> Void
    let onQuit: () -> Void

    @State private var elapsedSeconds: Int = 0
    @State private var timerTask: Task<Void, Never>?

    private var recordingStartedAt: Date? {
        if case .recording(let metadata) = coordinator.state {
            return metadata.startedAt
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLine
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            LoreDivider()

            primaryAction
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            LoreDivider()

            VStack(spacing: 2) {
                PopoverMenuRow(
                    title: "Show \(LoreTheme.wordmark)",
                    systemImage: "macwindow",
                    action: onShowMainWindow
                )
                PopoverMenuRow(
                    title: "Check for Updates…",
                    systemImage: "arrow.triangle.2.circlepath",
                    action: onCheckForUpdates
                )
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            LoreDivider()

            PopoverMenuRow(
                title: "Quit \(LoreTheme.wordmark)",
                systemImage: "power",
                muted: true,
                action: onQuit
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(width: 280)
        .background(LoreTheme.Surface.popover)
        .onAppear {
            if coordinator.isRecording {
                startTimer()
            }
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: coordinator.isRecording) { _, recording in
            if recording {
                startTimer()
            } else {
                stopTimer()
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if coordinator.isRecording {
                Circle()
                    .fill(LoreTheme.Accent.red)
                    .frame(width: 8, height: 8)
                Text("Recording — \(formattedTime)")
                    .font(LoreTheme.Typography.control)
                    .foregroundStyle(LoreTheme.TextColor.primary)
            } else if settings.meetingAutoDetectEnabled {
                Circle()
                    .fill(LoreTheme.TextColor.muted)
                    .frame(width: 8, height: 8)
                Text("Listening for meetings…")
                    .font(LoreTheme.Typography.secondary)
                    .foregroundStyle(LoreTheme.TextColor.muted)
            } else {
                Circle()
                    .fill(LoreTheme.TextColor.faint)
                    .frame(width: 8, height: 8)
                Text("Idle")
                    .font(LoreTheme.Typography.secondary)
                    .foregroundStyle(LoreTheme.TextColor.muted)
            }
            Spacer()
        }
    }

    private var primaryAction: some View {
        // Canonical redesign Start/Stop control; behavior preserved (D-031).
        // The consent detour is gone (#150): the menu bar only exists once setup
        // completed, and completing it is the acknowledgement.
        LoreStartStopButton(isRecording: coordinator.isRecording) {
            if coordinator.isRecording {
                coordinator.handle(.userStopped, settings: settings)
            } else {
                coordinator.handle(.userStarted(.manual()), settings: settings)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var formattedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func startTimer() {
        updateElapsed()
        stopTimer()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                updateElapsed()
            }
        }
    }

    private func updateElapsed() {
        if let start = recordingStartedAt {
            elapsedSeconds = max(0, Int(Date().timeIntervalSince(start)))
        } else {
            elapsedSeconds = 0
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        elapsedSeconds = 0
    }
}

/// Full-width popover menu row: leading SF Symbol + label, Lore hover fill.
/// `muted` renders the destructive/secondary Quit action.
private struct PopoverMenuRow: View {
    let title: String
    var systemImage: String
    var muted = false
    let action: () -> Void

    var body: some View {
        let tint = muted ? LoreTheme.TextColor.muted : LoreTheme.TextColor.primary
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(LoreTheme.Typography.secondary)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .loreHoverFill(cornerRadius: LoreTheme.Radius.button)
    }
}
