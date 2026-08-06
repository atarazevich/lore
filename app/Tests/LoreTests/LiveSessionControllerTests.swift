import XCTest
import Observation
@testable import LoreKit

@MainActor
final class LiveSessionControllerTests: XCTestCase {

    // MARK: - Tests

    func testStartSessionTransitionsStateToRecordingSynchronously() {
        let h = MeetingHarness.make()

        XCTAssertEqual(h.coordinator.state, .idle)

        h.controller.startSession(settings: h.settings)

        // The state machine transition must happen synchronously
        if case .recording = h.coordinator.state {
            // expected
        } else {
            XCTFail("Expected .recording state immediately after startSession, got \(h.coordinator.state)")
        }
    }

    func testStartSessionWhileRunningIsNoOp() async {
        let h = await MeetingHarness.makeStarted(scripted: [Utterance(text: "Test", speaker: .you)])

        // Second start should be a no-op (chokepoint: session already active)
        h.controller.startSession(settings: h.settings)

        // Still recording, not crashed or changed
        if case .recording = h.coordinator.state {
            // expected
        } else {
            XCTFail("Expected .recording state, got \(h.coordinator.state)")
        }
    }

    /// Ghost-recording regression: a stop arriving while the start's session
    /// setup is still in flight is bounce from the same interaction (the
    /// header button flips to "Stop" the instant coordinator.state changes)
    /// and must be dropped — the recording continues, and a deliberate stop
    /// afterwards still works.
    func testStopDuringStartWindowIsDroppedAsBounce() async {
        let h = MeetingHarness.make(scripted: [Utterance(text: "Hello", speaker: .you)])

        h.controller.startSession(settings: h.settings)
        h.controller.stopSession(settings: h.settings)

        if case .recording = h.coordinator.state {
            // expected — the bounce stop was dropped
        } else {
            XCTFail("Expected .recording after bounce stop, got \(h.coordinator.state)")
        }

        // The recording proceeds to a working engine.
        await waitUntil { h.coordinator.transcriptionEngine?.isRunning == true }
        XCTAssertEqual(h.coordinator.transcriptionEngine?.isRunning, true)

        // A deliberate stop after the session is established passes through.
        h.controller.stopSession(settings: h.settings)
        await waitUntil { h.coordinator.state == .idle }
        XCTAssertEqual(h.coordinator.state, .idle)
        XCTAssertEqual(h.coordinator.transcriptionEngine?.isRunning, false)
    }

    /// Ghost-recording regression: engine capturing while the coordinator is
    /// idle (the ghost condition itself) — a start must not stack a new
    /// session on top of a live capture.
    func testStartSessionNoOpsWhileEngineRunning() async {
        let h = MeetingHarness.make(scripted: [Utterance(text: "Hello", speaker: .you)])

        await h.coordinator.transcriptionEngine?.start()
        XCTAssertEqual(h.coordinator.transcriptionEngine?.isRunning, true)
        XCTAssertEqual(h.coordinator.state, .idle)

        h.controller.startSession(settings: h.settings)

        XCTAssertEqual(
            h.coordinator.state, .idle,
            "Start must no-op while the engine is already capturing"
        )
    }

    func testStopSessionWhileIdleIsNoOp() {
        let h = MeetingHarness.make()

        XCTAssertEqual(h.coordinator.state, .idle)

        h.controller.stopSession(settings: h.settings)

        // Should still be idle
        XCTAssertEqual(h.coordinator.state, .idle)
    }

    func testDeepLinkStartRejectedWhenEngineNotReady() {
        // No transcription engine
        let h = MeetingHarness.make(withEngine: false)

        // Queue a start command
        h.coordinator.queueExternalCommand(.startSession)

        // Try handling - should not start because engines are not ready
        h.controller.handlePendingExternalCommandIfPossible(settings: h.settings, showPastMeetings: nil)

        // Command should still be pending (not consumed)
        XCTAssertNotNil(h.coordinator.pendingExternalCommand)
        XCTAssertEqual(h.coordinator.state, .idle)
    }

    func testDeepLinkStopRejectedWhenNotRunning() {
        let h = MeetingHarness.make()

        h.coordinator.queueExternalCommand(.stopSession)

        // Try handling - should not stop because not running
        h.controller.handlePendingExternalCommandIfPossible(settings: h.settings, showPastMeetings: nil)

        // Command should still be pending (not consumed because guard failed)
        XCTAssertNotNil(h.coordinator.pendingExternalCommand)
        XCTAssertEqual(h.coordinator.state, .idle)
    }

    func testDeepLinkOpenNotesAlwaysAccepted() {
        let h = MeetingHarness.make()

        h.coordinator.queueExternalCommand(.openNotes(sessionID: "test_session"))

        var notesOpened = false
        h.controller.handlePendingExternalCommandIfPossible(settings: h.settings) {
            notesOpened = true
        }

        XCTAssertTrue(notesOpened)
        XCTAssertNil(h.coordinator.pendingExternalCommand)
        XCTAssertEqual(h.coordinator.requestedSessionSelectionID, "test_session")
    }

    func testRunningStateChangeCallbackFires() async {
        let h = await MeetingHarness.makeStarted(scripted: [Utterance(text: "Hello", speaker: .you)])

        let engineRunning = h.coordinator.transcriptionEngine?.isRunning ?? false
        XCTAssertTrue(engineRunning, "Engine should be running after start")
    }

    func testConfirmDownloadSetsFlag() {
        let h = MeetingHarness.make()

        XCTAssertFalse(h.coordinator.transcriptionEngine?.downloadConfirmed ?? true)

        h.controller.confirmDownloadAndStart(settings: h.settings)

        XCTAssertTrue(h.coordinator.transcriptionEngine?.downloadConfirmed ?? false)
    }

    func testFullSessionLifecycle() async {
        let h = await MeetingHarness.makeStarted(scripted: [
            Utterance(text: "Let me walk through this.", speaker: .you),
            Utterance(text: "Sounds good.", speaker: .them),
        ])

        h.controller.stopSession(settings: h.settings)

        await waitUntil {
            h.coordinator.state == .idle && h.coordinator.lastEndedSession != nil
        }

        XCTAssertEqual(h.coordinator.state, .idle)
        XCTAssertNotNil(h.coordinator.lastEndedSession)
        XCTAssertEqual(h.coordinator.lastEndedSession?.utteranceCount, 2)
    }

    // MARK: - Change-gated publish (#142)

    /// Sendable flag for `withObservationTracking`'s onChange; the mutation
    /// happens synchronously on the main actor in these tests.
    private final class PublishFlag: @unchecked Sendable {
        var published = false
    }

    /// Registers observation of `controller.state` and reports whether the
    /// next `refreshState` published it.
    private func statePublished(
        by h: MeetingHarness, during mutate: () -> Void
    ) -> Bool {
        let flag = PublishFlag()
        withObservationTracking {
            _ = h.controller.state
        } onChange: {
            flag.published = true
        }
        mutate()
        return flag.published
    }

    func testRefreshDoesNotPublishOnIdenticalSnapshot() {
        let h = MeetingHarness.make()
        h.controller.refreshState(settings: h.settings)

        let published = statePublished(by: h) {
            h.controller.refreshState(settings: h.settings)
        }

        XCTAssertFalse(published, "Identical snapshot must not publish state")
    }

    func testRefreshPublishesOnChangedSnapshot() {
        let h = MeetingHarness.make()
        h.controller.refreshState(settings: h.settings)

        let published = statePublished(by: h) {
            h.coordinator.batchStatus = .transcribing(progress: 0.5, sessionID: "s1")
            h.controller.refreshState(settings: h.settings)
        }

        XCTAssertTrue(published, "A changed snapshot must publish state")
        XCTAssertEqual(
            h.controller.state.batchStatus,
            .transcribing(progress: 0.5, sessionID: "s1")
        )
    }

    // MARK: - Adaptive poll cadence (#142)

    func testPollIntervalSwitchesWithRunningSession() async {
        let h = await MeetingHarness.makeStarted(scripted: [Utterance(text: "Hello", speaker: .you)])
        h.controller.refreshState(settings: h.settings)

        XCTAssertEqual(h.controller.pollInterval, .milliseconds(250))

        h.controller.stopSession(settings: h.settings)
        await waitUntil { h.coordinator.state == .idle }
        h.controller.refreshState(settings: h.settings)

        XCTAssertEqual(
            h.controller.pollInterval, .seconds(2),
            "Cadence must drop back to the heartbeat once the session ends"
        )
    }

    func testPollIntervalSwitchesWithBatchStatus() {
        let h = MeetingHarness.make()

        h.coordinator.batchStatus = .transcribing(progress: 0.1, sessionID: "s1")
        h.controller.refreshState(settings: h.settings)
        XCTAssertEqual(h.controller.pollInterval, .milliseconds(250))

        h.coordinator.batchStatus = .idle
        h.controller.refreshState(settings: h.settings)
        XCTAssertEqual(h.controller.pollInterval, .seconds(2))

        h.coordinator.batchIsImporting = true
        h.controller.refreshState(settings: h.settings)
        XCTAssertEqual(h.controller.pollInterval, .milliseconds(250))

        h.coordinator.batchIsImporting = false
        h.controller.refreshState(settings: h.settings)
        XCTAssertEqual(h.controller.pollInterval, .seconds(2))
    }

    /// A `lore://` deep link queued while the app is otherwise idle must
    /// switch the loop to the fast cadence — a remote start waiting out the
    /// 2 s heartbeat widens the lost-audio window 8×.
    func testPollIntervalFastWithPendingExternalCommand() {
        let h = MeetingHarness.make()
        h.controller.refreshState(settings: h.settings)

        h.coordinator.queueExternalCommand(.startSession)
        XCTAssertEqual(h.controller.pollInterval, .milliseconds(250))
    }
}
