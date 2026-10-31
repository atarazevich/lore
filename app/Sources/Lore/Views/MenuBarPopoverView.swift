import LoreCore
import SwiftUI

struct MenuBarPopoverView: View {
    let coordinator: AppCoordinator
    let settings: AppSettings
    let onShowMainWindow: () -> Void
    let onShowMeetings: () -> Void
    /// The dot's destination (#151): the amber bead says "look", this row is
    /// where looking happens.
    let onShowHealth: () -> Void
    let onCheckForUpdates: () -> Void
    let onQuit: () -> Void
    /// Closes the popover before the blocked condition's fix opens macOS's
    /// prompt or System Settings (#338).
    var onCloseForFix: () -> Void = {}

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
            // macOS blocking lore (#338): the message and its one button, at
            // the top, in place of the "needs a look" row for this condition.
            if let block = coordinator.healthMonitor?.permissionsBlock {
                PermissionsBlockMessage(block: block, perform: perform)
                LoreDivider()
            }

            // The whole meeting block, or none of it (#221, board frame E): no
            // status line, no Start/Stop, no Resume. The menu-bar icon itself
            // does not change — only what the popover opens on.
            if settings.meetingsEnabled {
                statusLine
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                LoreDivider()

                primaryAction
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                LoreDivider()
            }

            VStack(spacing: 2) {
                // Only while a condition actually stands, so the popover carries
                // no standing "check your health" nag — the row exists to answer
                // the amber bead the user just clicked on.
                // The blocked condition speaks in its own message above.
                if let standing = coordinator.healthMonitor?.sustainedSubjects
                    .subtracting([.permissionsBlocked]), !standing.isEmpty {
                    PopoverMenuRow(
                        title: MenuBarController.label(for: .health, standing: standing),
                        systemImage: "exclamationmark.circle",
                        accent: LoreTheme.Accent.amber,
                        action: onShowHealth
                    )
                }
                PopoverMenuRow(
                    title: "Show \(LoreBrand.wordmark)",
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
                title: "Quit \(LoreBrand.wordmark)",
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

    @ViewBuilder
    private var statusLine: some View {
        if coordinator.isPaused {
            // Steady amber, the vocabulary every paused surface shares (#153).
            statusRow(dot: LoreTheme.Accent.amber, pulses: false, text: "Paused",
                      font: LoreTheme.Typography.control, tint: LoreTheme.Accent.amber)
        } else if coordinator.isRecording {
            statusRow(dot: LoreTheme.Accent.red, pulses: true,
                      text: "Recording — \(formattedTime)",
                      font: LoreTheme.Typography.control, tint: LoreTheme.TextColor.primary)
        } else if settings.meetingAutoDetectEnabled {
            statusRow(dot: LoreTheme.TextColor.muted, pulses: false,
                      text: "Listening for meetings…",
                      font: LoreTheme.Typography.secondary, tint: LoreTheme.TextColor.muted)
        } else {
            statusRow(dot: LoreTheme.TextColor.faint, pulses: false, text: "Idle",
                      font: LoreTheme.Typography.secondary, tint: LoreTheme.TextColor.muted)
        }
    }

    private func statusRow(
        dot: Color, pulses: Bool, text: String, font: Font, tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            LorePulsingDot(color: dot, pulses: pulses)
            Text(text)
                .font(font)
                .foregroundStyle(tint)
            Spacer()
        }
    }

    private var primaryAction: some View {
        // Canonical redesign Start/Stop control; behavior preserved (D-031).
        // The consent detour is gone (#150): the menu bar only exists once setup
        // completed, and completing it is the acknowledgement.
        //
        // Paused (#153) puts Resume beside it: the toggle keeps meaning Stop
        // for the whole live session, so the menu bar can always end a meeting
        // it can see, and Resume is the way back into one.
        HStack(spacing: 8) {
            if coordinator.isPaused {
                LoreResumeButton {
                    coordinator.handle(.userResumed, settings: settings)
                }
            }
            LoreStartStopButton(isRecording: coordinator.state.isLive) {
                if coordinator.state.isLive {
                    coordinator.handle(.userStopped, settings: settings)
                } else {
                    coordinator.handle(.userStarted(.manual()), settings: settings)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The panel's own dispatch. The popover closes first: macOS's prompt or
    /// System Settings comes up over everything, and the next opening shows
    /// the stage that follows.
    private func perform(_ action: HealthRemedyAction) {
        onCloseForFix()
        action.perform(monitor: coordinator.healthMonitor)
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
    /// An accented row points somewhere rather than doing something, so it takes
    /// both the colour and the chevron. The health row carries the same amber as
    /// the bead that sent the user here, so the two read as one thing.
    var accent: Color? = nil
    let action: () -> Void

    var body: some View {
        let tint = accent ?? (muted ? LoreTheme.TextColor.muted : LoreTheme.TextColor.primary)
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
                if accent != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .loreHoverFill(cornerRadius: LoreTheme.Radius.button)
    }
}

/// The blocked condition's message (#338, `untrusted-after-reinstall.html`
/// §01/§04): the amber mark, one sentence, a hint, and one primary button.
private struct PermissionsBlockMessage: View {
    let block: PermissionsBlock
    let perform: (HealthRemedyAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LoreTheme.Accent.amber)
                .frame(width: 15, height: 15)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(block.message)
                    .font(LoreTheme.Typography.control)
                    .foregroundStyle(LoreTheme.TextColor.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = block.hint {
                    Text(hint)
                        .font(LoreTheme.Typography.meta)
                        .foregroundStyle(LoreTheme.TextColor.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
                LorePrimaryButton(title: block.actionLabel, size: .compact) { perform(block.action) }
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }
}
