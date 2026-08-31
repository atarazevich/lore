import XCTest
@testable import LoreKit

/// Live-vs-review decision of the Meetings destination (#43): the review
/// flip must be recording-scoped — idle-time navigation to review must never
/// make the next recording open on the review layout.
@MainActor
final class ShellModelTests: XCTestCase {

    /// (a) Stale review navigation while idle, then a recording starts →
    /// the live side is shown.
    func testIdleReviewNavigationDoesNotPoisonNextRecording() {
        let shell = ShellModel()
        var recording = false
        shell.isRecordingActive = { recording }

        // Past Meetings / View Notes / deep link while idle.
        shell.showMeetingsReview()
        XCTAssertEqual(shell.destination, .meetings)
        XCTAssertFalse(shell.meetingsReviewWhileRecording,
                       "review flag must not be set while idle")
        // Idle shows the review layout by default.
        XCTAssertFalse(shell.meetingsShowsLive())

        // Recording starts (any path) — boundary reset, live side wins.
        recording = true
        shell.handleRecordingStateChange(from: .idle, to: .recording(.manual()))
        XCTAssertTrue(shell.meetingsShowsLive())
    }

    /// (b) User flips to review mid-recording → review; recording ends and
    /// a new one starts → live again.
    func testMidRecordingReviewFlipDiesAtNextBoundary() {
        let shell = ShellModel()
        var recording = true
        shell.isRecordingActive = { recording }

        // Deep link / header switch during an active recording.
        shell.showMeetingsReview()
        XCTAssertTrue(shell.meetingsReviewWhileRecording)
        XCTAssertFalse(shell.meetingsShowsLive())

        // Recording ends → review layout while idle.
        recording = false
        shell.handleRecordingStateChange(from: .ending(.manual()), to: .idle)
        XCTAssertFalse(shell.meetingsShowsLive())

        // New recording starts → live again.
        recording = true
        shell.handleRecordingStateChange(from: .idle, to: .recording(.manual()))
        XCTAssertTrue(shell.meetingsShowsLive())
    }

    /// (c) Pinned-live gate flow unchanged for the one gate that survives #150
    /// (the model download): the pin shows the live UI while idle; clearing it
    /// without a recording returns to review; a recording start resets the pin
    /// and the live side shows via the recording state.
    func testPinnedLiveGateFlowUnchanged() {
        let shell = ShellModel()
        var recording = false
        shell.isRecordingActive = { recording }

        shell.destination = .meetings
        shell.meetingsPinnedLive = true
        XCTAssertEqual(shell.destination, .meetings)
        XCTAssertTrue(shell.meetingsShowsLive())
        XCTAssertFalse(shell.meetingsReviewWhileRecording)

        // Gate dismissed without a recording (ContentView clears the pin).
        shell.meetingsPinnedLive = false
        XCTAssertFalse(shell.meetingsShowsLive())

        // Gate led to a start: boundary reset, recording state drives live.
        shell.meetingsPinnedLive = true
        recording = true
        shell.handleRecordingStateChange(from: .idle, to: .recording(.manual()))
        XCTAssertFalse(shell.meetingsPinnedLive)
        XCTAssertTrue(shell.meetingsShowsLive())
    }

    /// Boundary mapping: `.ending` holds the user's current side while
    /// finalizing; `.recording` and `.idle` arrivals reset — including the
    /// coalesced .ending → .idle → .recording frame observed as a single
    /// .ending → .recording change.
    func testRecordingStateChangeBoundaryMapping() {
        let shell = ShellModel()
        shell.isRecordingActive = { true }

        // Mid-recording flip, then stop: .ending arrival holds the flag.
        shell.showMeetingsReview()
        XCTAssertTrue(shell.meetingsReviewWhileRecording)
        shell.handleRecordingStateChange(from: .recording(.manual()), to: .ending(.manual()))
        XCTAssertTrue(shell.meetingsReviewWhileRecording,
                      "finalizing keeps the user's current side")

        // .idle arrival resets.
        shell.handleRecordingStateChange(from: .ending(.manual()), to: .idle)
        XCTAssertFalse(shell.meetingsReviewWhileRecording)

        // .recording arrival resets (coalesced-boundary case: observed
        // directly after .ending, without an intermediate .idle update).
        shell.showMeetingsReview()
        shell.handleRecordingStateChange(from: .ending(.manual()), to: .recording(.manual()))
        XCTAssertFalse(shell.meetingsReviewWhileRecording)
        XCTAssertFalse(shell.meetingsPinnedLive)
        XCTAssertTrue(shell.meetingsShowsLive())
    }

    /// A pause happens mid-session, so it is not a boundary (#153): the user
    /// stays on whichever side they were reading, and the resume — which
    /// arrives as `.recording` — must not yank them off it either.
    func testPauseAndResumeAreNotBoundaries() {
        let shell = ShellModel()
        shell.isRecordingActive = { true }

        shell.showMeetingsReview()
        XCTAssertTrue(shell.meetingsReviewWhileRecording)

        shell.handleRecordingStateChange(from: .recording(.manual()), to: .paused(.manual()))
        XCTAssertTrue(shell.meetingsReviewWhileRecording,
                      "pausing keeps the user's current side")
        XCTAssertFalse(shell.meetingsShowsLive())

        // The resume arrives as `.recording`, but it continues the same
        // session — it must not reset the side either.
        shell.handleRecordingStateChange(from: .paused(.manual()), to: .recording(.manual()))
        XCTAssertTrue(shell.meetingsReviewWhileRecording,
                      "a resume is not a boundary")
        XCTAssertFalse(shell.meetingsShowsLive())
    }

    /// The default provider treats the app as idle, so early navigation
    /// (before wiring) can never poison the flag.
    func testDefaultRecordingProviderIsIdle() {
        let shell = ShellModel()
        shell.showMeetingsReview()
        XCTAssertFalse(shell.meetingsReviewWhileRecording)
    }

    /// #220: Stats is its own sidebar entry (formerly the Activity half of
    /// DictationView's History/Activity switch) with the statistics glyph.
    func testStatsIsAnEnabledDestinationWithTheStatsGlyph() {
        XCTAssertTrue(ShellModel.enabledDestinations(meetingsEnabled: true).contains(.stats))
        XCTAssertEqual(ShellDestination.stats.icon, "chart.bar.xaxis")
        XCTAssertEqual(ShellDestination.stats.title, "Stats")
    }

    // MARK: - The Meetings master switch (#221)

    /// Off, Meetings is not in the sidebar at all — not greyed out, not last.
    /// Everything else keeps its place and its order.
    func testMeetingsLeavesTheSidebarWhenTheSwitchIsOff() {
        XCTAssertEqual(ShellModel.enabledDestinations(meetingsEnabled: true),
                       [.dictation, .meetings, .stats, .settings])
        XCTAssertEqual(ShellModel.enabledDestinations(meetingsEnabled: false),
                       [.dictation, .stats, .settings])
    }

    /// Switching it off while the user is standing on Meetings lands them on
    /// Dictation, and takes the recording-scoped flags with it — no boundary
    /// will ever arrive to clear them once the destination is gone.
    func testDestinationFallsBackToDictationWhenMeetingsGoesAway() {
        let shell = ShellModel()
        shell.isRecordingActive = { true }
        shell.showMeetingsReview()
        shell.meetingsPinnedLive = true
        XCTAssertEqual(shell.destination, .meetings)

        shell.meetingsSwitchChanged(to: false)

        XCTAssertEqual(shell.destination, .dictation)
        XCTAssertFalse(shell.meetingsPinnedLive)
        XCTAssertFalse(shell.meetingsReviewWhileRecording)
    }

    /// Standing anywhere else, the switch moves nothing.
    func testSwitchingMeetingsOffLeavesAnotherDestinationAlone() {
        let shell = ShellModel()
        shell.destination = .stats
        shell.meetingsSwitchChanged(to: false)
        XCTAssertEqual(shell.destination, .stats)
    }

    /// Turning it back on navigates nowhere: the sidebar item returns and the
    /// destination mounts, but the user stays where they are.
    func testSwitchingMeetingsOnDoesNotNavigate() {
        let shell = ShellModel()
        shell.destination = .dictation
        shell.meetingsSwitchChanged(to: true)
        XCTAssertEqual(shell.destination, .dictation)
    }

    /// Every door into Meetings asks the one switch — the menu bar, a deep
    /// link, a notification tap and the REC pill all arrive through these two.
    func testMeetingsDoorsAreNoOpsWhileTheSwitchIsOff() {
        let shell = ShellModel()
        shell.isRecordingActive = { true }
        shell.isMeetingsEnabled = { false }

        shell.showMeetings()
        XCTAssertEqual(shell.destination, .dictation)

        shell.showMeetingsReview()
        XCTAssertEqual(shell.destination, .dictation)
        XCTAssertFalse(shell.meetingsReviewWhileRecording,
                       "a refused navigation must not leave the flip behind")
    }

    /// Unwired, the shell behaves exactly as it did before the switch existed.
    func testDefaultMeetingsProviderIsOn() {
        let shell = ShellModel()
        shell.showMeetings()
        XCTAssertEqual(shell.destination, .meetings)
    }
}
