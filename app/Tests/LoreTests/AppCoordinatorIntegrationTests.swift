import XCTest
@testable import LoreKit

@MainActor
final class AppCoordinatorIntegrationTests: XCTestCase {

    func testUserStoppedFinalizesSessionAndRefreshesHistory() async {
        let h = MeetingHarness.make(scripted: [
            Utterance(text: "Let me walk through the rollout plan.", speaker: .you),
            Utterance(text: "The pilot scope sounds good to me.", speaker: .them),
        ])

        let metadata = MeetingMetadata(
            detectionContext: DetectionContext(
                signal: .manual,
                detectedAt: Date(),
                meetingApp: nil,
                calendarEvent: nil
            ),
            calendarEvent: nil,
            title: "Coordinator Test",
            startedAt: Date(),
            endedAt: nil
        )

        h.coordinator.handle(.userStarted(metadata), settings: h.settings)
        await waitUntil { h.coordinator.transcriptionEngine?.isRunning == true }

        h.coordinator.handle(.userStopped, settings: h.settings)
        await waitUntil {
            h.coordinator.lastEndedSession != nil && !h.coordinator.sessionHistory.isEmpty
        }

        guard let endedSession = h.coordinator.lastEndedSession else {
            XCTFail("Expected finalized session")
            return
        }

        XCTAssertEqual(endedSession.utteranceCount, 2)
        XCTAssertTrue(h.coordinator.sessionHistory.contains(where: { $0.id == endedSession.id }))

        let indices = await h.sessionRepository.listSessions()
        let persisted = indices.first(where: { $0.id == endedSession.id })
        XCTAssertNotNil(persisted)
        XCTAssertEqual(persisted?.utteranceCount, 2)
        XCTAssertFalse(persisted?.hasNotes ?? true)
    }

    func testFinalizationWritesSidecarWithCorrectMetadata() async {
        let h = MeetingHarness.make(scripted: [
            Utterance(text: "Hello from you.", speaker: .you),
            Utterance(text: "Hello from them.", speaker: .them),
        ])

        h.coordinator.handle(.userStarted(MeetingMetadata.manual()), settings: h.settings)
        await waitUntil { h.coordinator.transcriptionEngine?.isRunning == true }

        h.coordinator.handle(.userStopped, settings: h.settings)
        await waitUntil {
            h.coordinator.state == .idle && h.coordinator.lastEndedSession != nil
        }

        XCTAssertEqual(h.coordinator.state, .idle)

        let indices = await h.sessionRepository.listSessions()
        XCTAssertFalse(indices.isEmpty)
        let session = indices.first!
        XCTAssertFalse(session.hasNotes)
        XCTAssertEqual(session.utteranceCount, 2)
    }

    /// Ghost-recording regression: a stop dispatched back-to-back with a start
    /// (no waiting for the engine — e.g. menu-bar stop right after start) must
    /// await the start's session setup, finalize THAT session, and leave the
    /// engine stopped. Before the lifecycle chain, finalize could run first,
    /// finalize a nil/"unknown" session, and the pending start would then
    /// launch a capture detached from any session.
    func testStopImmediatelyAfterStartFinalizesStartedSession() async {
        let h = MeetingHarness.make(scripted: [Utterance(text: "Quick note.", speaker: .you)])

        h.coordinator.handle(.userStarted(MeetingMetadata.manual()), settings: h.settings)
        h.coordinator.handle(.userStopped, settings: h.settings)

        await waitUntil {
            h.coordinator.state == .idle && h.coordinator.lastEndedSession != nil
        }

        XCTAssertEqual(h.coordinator.state, .idle)
        XCTAssertEqual(
            h.coordinator.transcriptionEngine?.isRunning, false,
            "Engine must never keep capturing after the state returns to idle"
        )

        let indices = await h.sessionRepository.listSessions()
        XCTAssertEqual(indices.count, 1, "Exactly the started session — no ghost/unknown entries")
        XCTAssertEqual(h.coordinator.lastEndedSession?.id, indices.first?.id)
        XCTAssertNotNil(indices.first?.endedAt, "The started session must be properly ended")
    }

    /// Effect-order probe: the serial chain must run the start's session setup
    /// strictly before the stop's finalize — deterministically, not by luck.
    /// The probe is enqueued between the two entries, so it observes the world
    /// after startTranscription and before finalizeCurrentSession.
    func testStopEffectRunsAfterStartSetup() async {
        let h = MeetingHarness.make(scripted: [Utterance(text: "Hi", speaker: .you)])
        var sessionExistedBeforeFinalize = false

        h.coordinator.handle(.userStarted(MeetingMetadata.manual()), settings: h.settings)
        h.coordinator.enqueueLifecycleEffect { [sessionRepository = h.sessionRepository] in
            sessionExistedBeforeFinalize = await sessionRepository.getCurrentSessionID() != nil
        }
        h.coordinator.handle(.userStopped, settings: h.settings)

        await waitUntil {
            h.coordinator.state == .idle && h.coordinator.lastEndedSession != nil
        }

        XCTAssertTrue(
            sessionExistedBeforeFinalize,
            "Start setup must complete (session established) before the stop's finalize begins"
        )
        XCTAssertEqual(h.coordinator.transcriptionEngine?.isRunning, false)
    }

    /// Timeout while finalize hangs: the timeout must fire (armed when
    /// finalize begins), force idle, and drop the chain so the next
    /// start/stop run fresh instead of queueing behind the hung finalize.
    /// The hang is real: a delayed live write keeps `awaitPendingWrites`
    /// suspended for ~5s (the repo's delayed-write enrichment window).
    func testFinalizationTimeoutResetsChainAndRecovers() async {
        let h = await MeetingHarness.makeStarted(scripted: [Utterance(text: "One", speaker: .you)])
        h.coordinator.finalizationTimeout = .milliseconds(200)

        let sessionID1 = await h.sessionRepository.getCurrentSessionID()
        XCTAssertNotNil(sessionID1)
        await h.sessionRepository.appendLiveUtterance(
            sessionID: sessionID1 ?? "",
            utterance: Utterance(text: "delayed", speaker: .them),
            metadata: LiveUtteranceMetadata(isDelayed: true)
        )

        h.controller.stopSession(settings: h.settings)

        let timedOut = await waitUntil(timeout: .seconds(2)) { h.coordinator.state == .idle }
        XCTAssertTrue(timedOut, "Timeout must force idle while finalize hangs")

        // Session IDs have second resolution — space the second session out.
        try? await Task.sleep(for: .milliseconds(1100))

        // The chain was dropped: the next start must not wait ~5s on the hung finalize.
        h.controller.startSession(settings: h.settings)
        let recording = await waitUntil(timeout: .seconds(2)) {
            h.coordinator.isRecording && h.coordinator.transcriptionEngine?.isRunning == true
        }
        XCTAssertTrue(recording, "A start after the timeout must run on a fresh chain")

        h.controller.stopSession(settings: h.settings)
        let stopped = await waitUntil(timeout: .seconds(10)) {
            h.coordinator.state == .idle && h.coordinator.transcriptionEngine?.isRunning != true
        }
        XCTAssertTrue(stopped)

        // Once the delayed write flushes, both finalizes complete against
        // their own sessions (entry-bound IDs): no ghosts left on disk.
        var allEnded = false
        for _ in 0..<100 {
            let sessions = await h.sessionRepository.listSessions()
            if sessions.count == 2, sessions.allSatisfy({ $0.endedAt != nil }) {
                allEnded = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(allEnded, "Both sessions must end up finalized with endedAt — no ghosts")
    }

    /// `.finalizationTimeout` invalidates lifecycle effects that were queued
    /// (but not started) behind the hung one, and new effects run fresh.
    func testTimeoutInvalidatesQueuedLifecycleEffects() async {
        let coordinator = AppCoordinator()

        coordinator.enqueueLifecycleEffect { try? await Task.sleep(for: .milliseconds(300)) }
        var staleRan = false
        coordinator.enqueueLifecycleEffect { staleRan = true }

        // Reach .ending so the timeout event transitions (side effects only
        // fire on a state change), then time out.
        coordinator.handle(.userStarted(MeetingMetadata.manual()))
        coordinator.handle(.userStopped)
        coordinator.handle(.finalizationTimeout)
        XCTAssertEqual(coordinator.state, .idle)

        var freshRan = false
        coordinator.enqueueLifecycleEffect { freshRan = true }

        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(staleRan, "Effects queued before the timeout must not run after the chain is dropped")
        XCTAssertTrue(freshRan, "Effects enqueued after the reset run on a fresh chain")
    }

    /// Generation binding: a finalize that outlived its timeout must not
    /// complete a LATER stop's finalization — neither flip its `.ending` to
    /// `.idle` nor cancel its timer.
    func testLateFinalizeCompletionDoesNotDisturbLaterStop() async {
        let coordinator = AppCoordinator() // no controller: entries are no-op awaits

        // Cycle 1 establishes generation 1 (its finalize completes normally).
        coordinator.handle(.userStarted(MeetingMetadata.manual()))
        coordinator.handle(.userStopped)
        await waitUntil { coordinator.state == .idle }

        // Hold the next stop in .ending by blocking the chain, so its
        // finalize entry stays queued.
        coordinator.enqueueLifecycleEffect { try? await Task.sleep(for: .seconds(3600)) }
        coordinator.handle(.userStarted(MeetingMetadata.manual()))
        coordinator.handle(.userStopped) // generation 2
        guard case .ending = coordinator.state else {
            XCTFail("Expected .ending while finalize is queued, got \(coordinator.state)")
            return
        }

        // Cycle 1's finalize completing late must be a no-op.
        coordinator.completeFinalization(generation: 1)
        if case .ending = coordinator.state {
            // expected — stale completion ignored
        } else {
            XCTFail("Stale finalize completion must not disturb a later stop, got \(coordinator.state)")
        }

        // The current generation's completion still works.
        coordinator.completeFinalization(generation: 2)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testFinalizationTimeoutForcesIdleState() async {
        let coordinator = AppCoordinator()
        let metadata = MeetingMetadata.manual()

        coordinator.handle(.userStarted(metadata))
        XCTAssertEqual(coordinator.isRecording, true)

        coordinator.handle(.userStopped)
        coordinator.handle(.finalizationTimeout)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testDiscardReturnsToIdleWithoutFinalization() async {
        let coordinator = AppCoordinator()
        let metadata = MeetingMetadata.manual()

        coordinator.handle(.userStarted(metadata))
        XCTAssertEqual(coordinator.isRecording, true)

        coordinator.handle(.userDiscarded)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.lastEndedSession)
    }

    // MARK: - Pause / Resume (#153)

    /// Pause suspends capture and leaves the session open; resume brings it
    /// back without a second session appearing anywhere.
    func testPauseSuspendsCaptureAndResumeContinuesTheSameSession() async {
        let h = await MeetingHarness.makeStarted()
        let sessionID = await h.sessionRepository.getCurrentSessionID()
        XCTAssertNotNil(sessionID)

        h.controller.pauseSession(settings: h.settings)
        let paused = await waitUntil {
            h.coordinator.isPaused && h.coordinator.transcriptionEngine?.isCapturing == false
        }
        XCTAssertTrue(paused, "Pause must stop capture while the session stays open")
        XCTAssertFalse(h.coordinator.isRecording, "A paused meeting is not recording")
        XCTAssertTrue(h.coordinator.state.isLive, "…but it is still a live session")

        h.controller.resumeSession(settings: h.settings)
        let resumed = await waitUntil {
            h.coordinator.isRecording && h.coordinator.transcriptionEngine?.isCapturing == true
        }
        XCTAssertTrue(resumed, "Resume must bring capture back")

        // Same session throughout: the resume never created a second one.
        let afterResume = await h.sessionRepository.getCurrentSessionID()
        XCTAssertEqual(afterResume, sessionID)
        XCTAssertEqual(h.controller.activeSessionID, sessionID)

        h.controller.stopSession(settings: h.settings)
        let stopped = await waitUntil(timeout: .seconds(10)) { h.coordinator.state == .idle }
        XCTAssertTrue(stopped)

        let sessions = await h.sessionRepository.listSessions()
        XCTAssertEqual(sessions.count, 1, "Pause and resume must yield exactly one session")
    }

    /// Stop from a pause finalizes — the user never has to resume first.
    func testStopFromPausedFinalizes() async {
        let h = await MeetingHarness.makeStarted()

        h.controller.pauseSession(settings: h.settings)
        await waitUntil { h.coordinator.isPaused }

        h.controller.stopSession(settings: h.settings)
        let ended = await waitUntil(timeout: .seconds(10)) { h.coordinator.state == .idle }
        XCTAssertTrue(ended, "A paused session must finalize on stop")

        let sessions = await h.sessionRepository.listSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNotNil(sessions.first?.endedAt, "The finalized session must carry an end date")
    }

    /// A second start while paused is rejected at the chokepoint — otherwise
    /// it would abandon the open session's files and transcript.
    func testStartWhilePausedIsRejected() async {
        let h = await MeetingHarness.makeStarted()
        let sessionID = await h.sessionRepository.getCurrentSessionID()

        h.controller.pauseSession(settings: h.settings)
        await waitUntil { h.coordinator.isPaused }

        XCTAssertFalse(h.coordinator.canStartCapture)
        h.controller.startSession(settings: h.settings)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(h.coordinator.isPaused, "A start must not disturb a paused session")
        let stillSame = await h.sessionRepository.getCurrentSessionID()
        XCTAssertEqual(stillSame, sessionID)
    }

    /// Pause needs live capture, not merely a committed start: a session still
    /// downloading its model has nothing to suspend, and pausing it would leave
    /// the user in a paused banner over an engine that then starts recording.
    func testPauseIsRejectedWithoutLiveCapture() async {
        let h = MeetingHarness.make(withEngine: false)
        h.controller.startSession(settings: h.settings)
        await waitUntil { h.coordinator.isRecording }

        h.controller.pauseSession(settings: h.settings)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(h.coordinator.isPaused, "Nothing to pause without capture")
        XCTAssertTrue(h.coordinator.isRecording)
    }

    /// A remote start aimed at a paused session means "make it record", which
    /// is a resume — a plain start would be rejected at the chokepoint and the
    /// command consumed for nothing (#153).
    func testExternalStartWhilePausedResumes() async {
        let h = await MeetingHarness.makeStarted()

        h.controller.pauseSession(settings: h.settings)
        await waitUntil { h.coordinator.isPaused }

        h.coordinator.queueExternalCommand(.startSession)
        h.controller.handlePendingExternalCommandIfPossible(
            settings: h.settings, showPastMeetings: nil
        )

        let resumed = await waitUntil { h.coordinator.isRecording }
        XCTAssertTrue(resumed, "lore://start on a paused meeting resumes it")
        XCTAssertNil(h.coordinator.pendingExternalCommand, "and the command is consumed")
    }
}
