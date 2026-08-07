import Observation

/// Sidebar destinations of the unified Lore window (SHELL-16).
///
/// The nav model is 5-capable — Tasks and Library are designed but ship in
/// Stage 2 — so adding them later is a `ShellModel.enabledDestinations` entry,
/// not a shell change (app-shell.md "Out of scope").
enum ShellDestination: String, CaseIterable, Identifiable {
    case dictation
    case meetings
    case tasks
    case library
    case settings

    var id: String { rawValue }

    /// Toolbar / nav title (SHELL-13).
    var title: String { rawValue.capitalized }

    /// SF Symbol per handoff README §SF Symbols map (SHELL-09).
    var icon: String {
        switch self {
        case .dictation: return "waveform"
        case .meetings: return "video"
        case .tasks: return "checkmark.circle"
        case .library: return "text.book.closed"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// Single navigation state of the shell — the one `view` selection the
/// prototype keeps (SHELL-16). Every action that used to open a separate
/// window navigates this model instead.
@Observable
@MainActor
final class ShellModel {
    /// Destinations rendered in Stage 1; Tasks/Library join in Stage 2.
    static let enabledDestinations: [ShellDestination] = [.dictation, .meetings, .settings]

    var destination: ShellDestination = .dictation

    /// Raised by the notch self-summon (#83) to open the health panel; the
    /// shell consumes it and clears it. A signal, not the panel's own state.
    var wantsHealthPanel = false

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

    /// Boundary mapping for the Meetings destination's state observer.
    /// `.ending` keeps the user's current side while finalizing; arrival at
    /// `.recording` or `.idle` resets to defaults. The observer is keyed to
    /// the full `MeetingState` (not a derived `== .idle` Bool): opposite
    /// transitions coalesced into one frame (.ending → .idle → .recording
    /// observed as .ending → .recording) leave a derived Bool unchanged and
    /// would skip the reset.
    func handleRecordingStateChange(_ state: MeetingState) {
        if case .ending = state { return }
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

    /// Navigate to Meetings as-is: live while recording, review otherwise.
    func showMeetings() {
        destination = .meetings
    }

    /// Navigate to the Meetings review side (replaces "open the Notes
    /// window", SHELL-18/19/29). While recording this flips the destination
    /// to review — deep links and notification taps land on the selection.
    /// While idle the review layout is already the default (`meetingsPinnedLive
    /// == false` shows it), so the recording-scoped flip flag stays untouched.
    func showMeetingsReview() {
        destination = .meetings
        meetingsPinnedLive = false
        meetingsReviewWhileRecording = isRecordingActive()
    }
}
