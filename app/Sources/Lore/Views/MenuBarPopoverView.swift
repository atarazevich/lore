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

            XMODivider()

            primaryAction
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            XMODivider()

            VStack(spacing: 2) {
                PopoverMenuRow(
                    title: "Show \(XMOTheme.wordmark)",
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

            XMODivider()

            PopoverMenuRow(
                title: "Quit \(XMOTheme.wordmark)",
                systemImage: "power",
                muted: true,
                action: onQuit
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(width: 280)
        .background(XMOTheme.Surface.popover)
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
                    .fill(XMOTheme.Accent.red)
                    .frame(width: 8, height: 8)
                Text("Recording — \(formattedTime)")
                    .font(XMOTheme.Typography.control)
                    .foregroundStyle(XMOTheme.TextColor.primary)
            } else if settings.meetingAutoDetectEnabled {
                Circle()
                    .fill(XMOTheme.TextColor.muted)
                    .frame(width: 8, height: 8)
                Text("Listening for meetings…")
                    .font(XMOTheme.Typography.secondary)
                    .foregroundStyle(XMOTheme.TextColor.muted)
            } else {
                Circle()
                    .fill(XMOTheme.TextColor.faint)
                    .frame(width: 8, height: 8)
                Text("Idle")
                    .font(XMOTheme.Typography.secondary)
                    .foregroundStyle(XMOTheme.TextColor.muted)
            }
            Spacer()
        }
    }

    private var primaryAction: some View {
        // Canonical redesign Start/Stop control; behavior preserved (D-031):
        // Stop while recording, otherwise gate on recording consent before Start.
        XMOStartStopButton(isRecording: coordinator.isRecording) {
            if coordinator.isRecording {
                coordinator.handle(.userStopped, settings: settings)
            } else {
                guard settings.hasAcknowledgedRecordingConsent else {
                    onShowMeetings()
                    return
                }
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

/// Full-width popover menu row: leading SF Symbol + label, XMO hover fill.
/// `muted` renders the destructive/secondary Quit action.
private struct PopoverMenuRow: View {
    let title: String
    var systemImage: String
    var muted = false
    let action: () -> Void

    var body: some View {
        let tint = muted ? XMOTheme.TextColor.muted : XMOTheme.TextColor.primary
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(XMOTheme.Typography.secondary)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .xmoHoverFill(cornerRadius: XMOTheme.Radius.button)
    }
}
