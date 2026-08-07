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
        shell.handleRecordingStateChange(.recording(.manual()))
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
        shell.handleRecordingStateChange(.idle)
        XCTAssertFalse(shell.meetingsShowsLive())

        // New recording starts → live again.
        recording = true
        shell.handleRecordingStateChange(.recording(.manual()))
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
        shell.handleRecordingStateChange(.recording(.manual()))
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
        shell.handleRecordingStateChange(.ending(.manual()))
        XCTAssertTrue(shell.meetingsReviewWhileRecording,
                      "finalizing keeps the user's current side")

        // .idle arrival resets.
        shell.handleRecordingStateChange(.idle)
        XCTAssertFalse(shell.meetingsReviewWhileRecording)

        // .recording arrival resets (coalesced-boundary case: observed
        // directly after .ending, without an intermediate .idle update).
        shell.showMeetingsReview()
        shell.handleRecordingStateChange(.recording(.manual()))
        XCTAssertFalse(shell.meetingsReviewWhileRecording)
        XCTAssertFalse(shell.meetingsPinnedLive)
        XCTAssertTrue(shell.meetingsShowsLive())
    }

    /// The default provider treats the app as idle, so early navigation
    /// (before wiring) can never poison the flag.
    func testDefaultRecordingProviderIsIdle() {
        let shell = ShellModel()
        shell.showMeetingsReview()
        XCTAssertFalse(shell.meetingsReviewWhileRecording)
    }
}
