import Observation

/// Sidebar destinations of the unified Lore window (SHELL-16).
///
/// The nav model is 5-capable — Tasks and Library are designed but ship in
/// Stage 2 — so adding them later is a `ShellModel.enabledDestinations` entry,
/// not a shell change (app-shell.md "Out of scope").
enum ShellDestination: String, CaseIterable, Identifiable {
    case dictation
    case meetings
    case stats
    case tasks
    case library
    case settings

    var id: String { rawValue }

    /// Toolbar / nav title (SHELL-13).
    var title: String { rawValue.capitalized }

    /// SF Symbol per handoff README §SF Symbols map (SHELL-09). `stats`
    /// (#220) reads as statistics at sidebar size — the Dictation Activity
    /// pane's own empty-state icon, promoted with it.
    var icon: String {
        switch self {
        case .dictation: return "waveform"
        case .meetings: return "video"
        case .stats: return "chart.bar.xaxis"
        case .tasks: return "checkmark.circle"
        case .library: return "text.book.closed"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// A section of the Settings destination, by name (#198). A navigation id, not
/// a layout: the cards and their order stay in `SettingsView`. Surfaces outside
/// the shell — the recording bubble's gear — name the section they want and
/// land on it.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case talk
    case copying
    case readAloud
    case modifiers
    case meetings
    case notes
    case advanced

    var id: String { rawValue }

    /// The one door for a surface that is not in the shell's environment: name
    /// the section, and the window comes forward showing it. Installed once by
    /// the scene (`LoreApp.wireDelegate`), which is the only place that can
    /// front a window; a no-op until then, so no caller has to ask whether the
    /// UI exists yet.
    @MainActor static var open: (SettingsSection) -> Void = { _ in }
}

/// Single navigation state of the shell — the one `view` selection the
/// prototype keeps (SHELL-16). Every action that used to open a separate
/// window navigates this model instead.
@Observable
@MainActor
final class ShellModel {
    /// Destinations rendered in Stage 1; Tasks/Library join in Stage 2. Stats
    /// (#220) is the former Dictation Activity pane, promoted to its own
    /// entry.
    ///
    /// Meetings is in the list only while its master switch is on (#221) — not
    /// greyed out and not moved down: absent.
    static func enabledDestinations(meetingsEnabled: Bool) -> [ShellDestination] {
        meetingsEnabled
            ? [.dictation, .meetings, .stats, .settings]
            : [.dictation, .stats, .settings]
    }

    var destination: ShellDestination = .dictation

    /// The health panel's presentation state, on the shared model rather than in
    /// `ShellView`'s `@State` so the menu bar can open it too (#151). One piece
    /// of state that both doors — the sidebar footer and the popover's health
    /// row — set directly; deliberately not a signal the view consumes and
    /// clears, which is the shape that made the deleted notch "Fix it" path
    /// three hops long.
    var presentsHealthPanel = false

    /// Stage E: the Meetings destination shows the designed review layout
    /// (NotesView) while idle. This flag pins the live UI (ContentView) on
    /// screen for the model-download gate — now its only remaining reason,
    /// which is why the pin is set at that one call site rather than through a
    /// helper. Cleared on every recording start/stop transition and whenever
    /// review is requested.
    var meetingsPinnedLive = false

    /// While recording the Meetings destination defaults to the live UI;
    /// this flips it to the review side (header switch, deep links).
    /// Recording-scoped: only ever set while a recording is active (#43 —
    /// a sticky true from idle-time navigation made the next recording open
    /// on the review layout). Reset on recording start and end.
    var meetingsReviewWhileRecording = false

    /// Single truth source for "is a meeting recording active", wired once at
    /// app setup. The closure retains the AppCoordinator one-directionally
    /// (no cycle — the coordinator never holds the shell; both live for the
    /// app's lifetime).
    @ObservationIgnored var isRecordingActive: () -> Bool = { false }

    /// Whether the Meetings surfaces exist at all (#221) — the master switch,
    /// wired once at app setup like `isRecordingActive`. Held as a closure so
    /// every door into Meetings asks the one switch here, rather than each
    /// caller (menu bar, deep link, REC pill, notification) remembering to.
    /// Defaults to on, so navigation before wiring behaves as it always did.
    @ObservationIgnored var isMeetingsEnabled: () -> Bool = { true }

    /// The one live-vs-review decision for the Meetings destination
    /// (extracted from the view for unit tests). Reading `coordinator.state`
    /// through the closure during body evaluation keeps SwiftUI's observation
    /// tracking intact.
    func meetingsShowsLive() -> Bool {
        isRecordingActive() ? !meetingsReviewWhileRecording : meetingsPinnedLive
    }

    /// Any recording start/stop boundary returns Meetings to its defaults:
    /// live side while recording, review layout when idle. Stale pins and
    /// review flips die here.
    func resetMeetingsForRecordingBoundary() {
        meetingsPinnedLive = false
        meetingsReviewWhileRecording = false
    }

    /// Boundary mapping for the Meetings destination's state observer. A
    /// boundary is a session beginning or ending; arriving at one resets the
    /// destination to its defaults (live side while recording, review when
    /// idle) and drops stale pins.
    ///
    /// Both states, not just the new one: opposite transitions coalesced into
    /// one frame (.ending → .idle → .recording observed as .ending →
    /// .recording) must still reset, while a resume — which also arrives at
    /// .recording — must not, because it continues the session the user was
    /// already reading around (#153).
    func handleRecordingStateChange(from old: MeetingState, to new: MeetingState) {
        // Mid-session phases keep the user's current side: finalizing, pausing,
        // and the resume that ends a pause — the last of which arrives at
        // `.recording` and is told from a real start only by where it came from.
        if case .ending = new { return }
        if case .paused = new { return }
        if old.isLive, case .recording = new { return }
        resetMeetingsForRecordingBoundary()
    }

    /// Set by ContentView. The review header's "Start recording" button routes
    /// through this so it reuses the one start path — and the model-download
    /// gate that still renders inside ContentView (MREV-05, D-031).
    @ObservationIgnored var requestMeetingRecordingStart: (() -> Void)?

    /// Set by ContentView. The review header's "Stop recording" button routes
    /// through the same guarded stop path as the live header (bounce guard in
    /// LiveSessionController.stopSession).
    @ObservationIgnored var requestMeetingRecordingStop: (() -> Void)?

    /// The Settings section a deep link asked for, cleared by the Settings
    /// screen the moment it has scrolled there (#198). Nil the rest of the
    /// time: nothing may read it as "the section you are in".
    var pendingSettingsSection: SettingsSection?

    /// Navigate to Settings, optionally at one section.
    func showSettings(_ section: SettingsSection? = nil) {
        destination = .settings
        pendingSettingsSection = section
    }

    /// Navigate to Meetings as-is: live while recording, review otherwise.
    /// A no-op while the master switch is off (#221) — there is no destination
    /// to land on.
    func showMeetings() {
        guard isMeetingsEnabled() else { return }
        destination = .meetings
    }

    /// Navigate to the Meetings review side (replaces "open the Notes
    /// window", SHELL-18/19/29). While recording this flips the destination
    /// to review — deep links and notification taps land on the selection.
    /// While idle the review layout is already the default (`meetingsPinnedLive
    /// == false` shows it), so the recording-scoped flip flag stays untouched.
    func showMeetingsReview() {
        guard isMeetingsEnabled() else { return }
        destination = .meetings
        meetingsPinnedLive = false
        meetingsReviewWhileRecording = isRecordingActive()
    }

    /// The master switch moved (#221). Meetings taken away while the user is
    /// standing on it would leave them on a destination that no longer renders,
    /// so the shell lands on Dictation; the recording-scoped Meetings flags go
    /// with the destination rather than waiting for a boundary that, with no
    /// Meetings, will never arrive. Turning it back on adds nothing here — the
    /// sidebar item returns and the destination mounts on its own.
    func meetingsSwitchChanged(to enabled: Bool) {
        guard !enabled else { return }
        if destination == .meetings { destination = .dictation }
        resetMeetingsForRecordingBoundary()
    }
}
