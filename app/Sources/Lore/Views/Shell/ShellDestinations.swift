import SwiftUI
import Sparkle

/// Stage B destination wrappers: host the existing views as-is inside the
/// unified shell (D-031 — functional behavior unchanged). Stage C/D restyle
/// and restructure their internals.

/// Dictation destination. The per-destination onboarding gate is gone (#150):
/// the shell is not mounted until setup completes, so by the time this renders
/// the world is already configured.
struct DictationDestination: View {
    @Bindable var settings: AppSettings
    let isActive: Bool

    var body: some View {
        DictationView(settings: settings, isActiveInShell: isActive)
    }
}

/// Meetings destination (Stage E): the designed review layout (NotesView)
/// when idle, the existing live UI (ContentView) while a recording runs or a
/// gate overlay pins the live view. While recording, a header-level switch
/// flips between the live side and the review side, so past meetings stay
/// browsable mid-recording. Both subtrees stay mounted: ContentView runs the
/// meeting polling loop and hosts the onboarding/consent gates; NotesView
/// consumes queued session selections (SHELL-19/20/29).
struct MeetingsDestination: View {
    @Bindable var settings: AppSettings
    @Environment(ShellModel.self) private var shell
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let recordingActive = shell.isRecordingActive()
        let showLive = shell.meetingsShowsLive()
        VStack(spacing: 0) {
            if recordingActive {
                liveReviewSwitch(showLive: showLive)
                LoreDivider()
            }
            ZStack {
                ContentView(settings: settings)
                    .shellKeepAlive(isActive: showLive)
                NotesView(
                    settings: settings,
                    isActiveInShell: shell.destination == .meetings && !showLive
                )
                .shellKeepAlive(isActive: !showLive)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: coordinator.state) { oldState, newState in
            shell.handleRecordingStateChange(from: oldState, to: newState)
        }
    }

    /// Compact segmented switch shown only during a session: "Live" (with the
    /// session dot — steady amber while paused, #153) vs "Meetings" (the review
    /// layout). Shared chip chrome: `LoreSegmentedSwitch` (#215 review — F6).
    private func liveReviewSwitch(showLive: Bool) -> some View {
        let paused = coordinator.isPaused
        return LoreSegmentedSwitch(
            isLeftSelected: showLive,
            selectLeft: { shell.meetingsReviewWhileRecording = false },
            selectRight: { shell.meetingsReviewWhileRecording = true }
        ) {
            LorePulsingDot(
                color: paused ? LoreTheme.Accent.amber : LoreTheme.Accent.red,
                size: 7,
                pulses: !paused
            )
            Text("Live")
        } rightLabel: {
            Text("Meetings")
        }
    }
}

/// Settings destination — the unified Lore settings screen (Stage D). The old
/// Cmd+, Settings scene is gone; this is the only Settings surface (SET-06).
struct SettingsDestination: View {
    @Bindable var settings: AppSettings
    let updater: SPUUpdater
    let isActive: Bool

    var body: some View {
        SettingsView(
            settings: settings,
            updater: updater,
            isActiveInShell: isActive
        )
    }
}
