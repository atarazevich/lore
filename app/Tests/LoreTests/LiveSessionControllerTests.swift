import AVFoundation
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

    // MARK: - Recording audio lives inside the meeting (#177)

    /// Collects the sessions a healer dispatches, so a sweep can be asserted
    /// without an ASR pass.
    @MainActor
    private final class DispatchLog {
        var sessionIDs: [String] = []
    }

    /// A harness with a real recorder wired before the session starts, plus
    /// the buffers a live capture would have delivered. Returns the session id
    /// and the recorder's track directory.
    private func startRecordingMeeting(
        _ h: MeetingHarness
    ) async -> (sessionID: String, trackDirectory: URL) {
        let recorder = AudioRecorder(
            outputDirectory: URL(fileURLWithPath: h.settings.notesFolderPath)
        )
        h.coordinator.audioRecorder = recorder
        h.controller.startSession(settings: h.settings)
        await waitUntil { h.coordinator.transcriptionEngine?.isRunning == true }

        let sessionID = h.controller.activeSessionID ?? ""
        XCTAssertFalse(sessionID.isEmpty, "the session must exist before capture")

        // What the capture taps do, minus the audio hardware.
        let buffer = makeSineBuffer(sampleRate: 48_000, frameCount: 48_000)
        recorder.writeMicBuffer(buffer)
        recorder.writeSysBuffer(buffer)

        // The repository owns the layout; asking it is what keeps this test
        // honest when the layout moves.
        let trackDirectory = await h.sessionRepository.prepareAudioDirectory(sessionID: sessionID)

        // Every test below reads what these two buffers wrote, and writing to
        // an unarmed recorder is a silent no-op — without this the whole file
        // would pass on nil and empty if arming ever regressed.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: BatchAudioStash.micURL(in: trackDirectory).path),
            "the recorder must be armed for this meeting before capture"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: BatchAudioStash.sysURL(in: trackDirectory).path)
        )
        return (sessionID, trackDirectory)
    }

    /// The promise: a force-quit or crash mid-meeting never loses what the
    /// user said. Nothing finalizes — the audio is already inside the meeting,
    /// and the next launch's sweep finds it and queues the rebuild with no
    /// manual step.
    func testMeetingKilledMidRecordingKeepsItsAudioAndIsSweptUp() async {
        let h = MeetingHarness.make(scripted: [Utterance(text: "Hello", speaker: .you)])
        let (sessionID, trackDirectory) = await startRecordingMeeting(h)

        // The kill: no stop, no finalize, no cleanup of any kind.
        let stash = await h.sessionRepository.batchAudioURLs(sessionID: sessionID)
        XCTAssertNotNil(stash.mic, "the mic track must already be the meeting's")
        XCTAssertNotNil(stash.sys, "the system track must already be the meeting's")
        // Read back through the reader the batch pass itself uses, so writer
        // and reader can't drift. Each track anchors itself in its own write,
        // so both are awaited — nothing here has drained the meta queue.
        await waitUntil {
            let meta = BatchAudioStash.readMeta(in: trackDirectory)
            return meta?.micStartDate != nil && meta?.sysStartDate != nil
        }
        let meta = await h.sessionRepository.loadBatchMeta(sessionID: sessionID)
        XCTAssertNotNil(
            meta?.micStartDate,
            "the timing anchors must be on disk, or the rebuilt transcript is stamped at rebuild time"
        )
        XCTAssertNotNil(meta?.sysStartDate)

        // The next launch: nothing is recording, and the sweep reads only what
        // is on disk.
        let log = DispatchLog()
        let healer = TranscriptHealer(
            repository: h.sessionRepository,
            liveSessionID: { nil },
            onRepaired: { _ in },
            runJob: { job in log.sessionIDs.append(job.sessionID); return .repaired },
            cancelRun: { }
        )
        await healer.sweep()
        await waitUntil { !log.sessionIDs.isEmpty }

        XCTAssertEqual(log.sessionIDs, [sessionID], "the killed meeting must be queued for rebuild")
    }

    /// A meeting that ends normally with batch refinement on keeps its tracks
    /// for the pass that is about to read them — finalization moves nothing.
    func testNormalStopLeavesTheStashForTheBatchPass() async {
        let h = MeetingHarness.make(scripted: [Utterance(text: "Hello", speaker: .you)])
        h.settings.enableBatchRefinement = true
        h.settings.saveAudioRecording = false
        let (sessionID, trackDirectory) = await startRecordingMeeting(h)

        h.controller.stopSession(settings: h.settings)
        await waitUntil { h.coordinator.state == .idle && h.coordinator.lastEndedSession != nil }

        let stash = await h.sessionRepository.batchAudioURLs(sessionID: sessionID)
        XCTAssertNotNil(stash.mic)
        XCTAssertNotNil(stash.sys)
        XCTAssertNotNil(BatchAudioStash.readMeta(in: trackDirectory)?.micStartDate)
    }

    /// With batch refinement off, nothing will read the tracks again: the
    /// meeting keeps its merged export and no raw audio accumulates.
    func testNormalStopWithoutBatchExportsAndLeavesNoRawAudio() async {
        let h = MeetingHarness.make(scripted: [Utterance(text: "Hello", speaker: .you)])
        h.settings.enableBatchRefinement = false
        h.settings.saveAudioRecording = true
        let (sessionID, _) = await startRecordingMeeting(h)

        h.controller.stopSession(settings: h.settings)
        await waitUntil { h.coordinator.state == .idle && h.coordinator.lastEndedSession != nil }

        let exports = ((try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: h.settings.notesFolderPath), includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "m4a" }
        XCTAssertEqual(exports.count, 1, "the merged export is the audio the user asked to keep")

        let stash = await h.sessionRepository.batchAudioURLs(sessionID: sessionID)
        XCTAssertNil(stash.mic, "no raw track may outlive a meeting nothing will re-transcribe")
        XCTAssertNil(stash.sys)
    }

    /// A discarded meeting leaves nothing behind: no export, and no tracks for
    /// a later sweep to resurrect. The delete goes by session id, so it can
    /// only ever remove the discarded meeting's own audio.
    ///
    /// Dispatched as the event, not by calling `discardSession()`: the discard
    /// runs on the same serial lifecycle chain as finalize, sharing its epoch,
    /// and that is the path the audio cleanup now lives inside.
    func testDiscardedMeetingLeavesNoAudioBehind() async {
        let h = MeetingHarness.make(scripted: [Utterance(text: "Hello", speaker: .you)])
        h.settings.enableBatchRefinement = true
        h.settings.saveAudioRecording = true
        let (sessionID, trackDirectory) = await startRecordingMeeting(h)

        h.coordinator.handle(.userDiscarded, settings: h.settings)
        XCTAssertEqual(h.coordinator.state, .idle, "the discard leaves no session behind")

        let removed = await waitUntil {
            !FileManager.default.fileExists(atPath: BatchAudioStash.micURL(in: trackDirectory).path)
        }
        XCTAssertTrue(removed, "the discard must remove the meeting's own audio")

        let stash = await h.sessionRepository.batchAudioURLs(sessionID: sessionID)
        XCTAssertNil(stash.mic, "a discarded meeting keeps no audio for the sweep to find")
        XCTAssertNil(stash.sys)
        let meta = await h.sessionRepository.loadBatchMeta(sessionID: sessionID)
        XCTAssertNil(meta, "the timing meta goes with the tracks")

        let exports = ((try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: h.settings.notesFolderPath), includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "m4a" }
        XCTAssertTrue(exports.isEmpty, "a discarded meeting produces no export")
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
