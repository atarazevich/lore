import Foundation
import os
import Observation
import CoreAudio

private let liveLog = Logger(subsystem: "com.lore.app", category: "LiveSession")

/// Published state for the live session, projected by ContentView.
/// Equatable so the polling loop publishes only on actual change (#142) —
/// Array `==` short-circuits on identical COW buffers, so comparing the
/// transcript is cheap when unchanged.
struct LiveSessionState: Equatable {
    var isRunning: Bool = false
    /// Audio is actually flowing — a mic stream is subscribed. `isRunning` is
    /// true from the moment a start commits, model download and all, so only
    /// this may gate the Pause control (#153).
    var isCapturing: Bool = false
    var sessionPhase: MeetingState = .idle
    var audioLevel: Float = 0
    var liveTranscript: [Utterance] = []
    var volatileYouText: String = ""
    var volatileThemText: String = ""
    var batchStatus: BatchTranscriptionEngine.Status = .idle
    var batchIsImporting: Bool = false
    var lastEndedSession: SessionIndex? = nil
    var statusMessage: String? = nil
    var errorMessage: String? = nil
    var needsDownload: Bool = false
    var downloadProgress: Double? = nil
    var showLiveTranscript: Bool = true
    var isMicMuted: Bool = false
}

/// Owns all live session side effects: polling, utterance ingestion,
/// settings change tracking, session start/stop, and finalization.
/// ContentView becomes a pure projection of this controller's state.
@Observable
@MainActor
final class LiveSessionController {
    private(set) var state = LiveSessionState()

    private let coordinator: AppCoordinator
    private let container: AppContainer

    // Tracked-change sentinels
    private var observedUtteranceCount = 0
    private var observedNotesFolderPath = ""
    private var observedInputDeviceID: AudioDeviceID = 0
    private var observedPendingExternalCommandID: UUID?

    init(coordinator: AppCoordinator, container: AppContainer) {
        self.coordinator = coordinator
        self.container = container
    }

    // MARK: - Initialization

    /// One-time setup tasks called when the view first appears.
    func performInitialSetup(settings: AppSettings) async {
        await coordinator.sessionRepository.purgeRecentlyDeleted()

        // The notes folder must be known BEFORE the healer sweep looks for
        // merged m4a exports (#166): a sweep racing the first poll tick would
        // otherwise misread m4a-recoverable meetings as unrecoverable.
        let notesURL = URL(fileURLWithPath: settings.notesFolderPath)
        await coordinator.sessionRepository.setNotesFolderPath(notesURL)

        // Launch backfill sweep (#107): every meeting without a summary gets
        // enriched on-device, one at a time, at background priority. No-op
        // when the model is unavailable; nil engine in UI-test mode.
        if let engine = coordinator.enrichmentEngine {
            Task.detached(priority: .background) {
                await engine.sweep()
            }
        }

        // Transcript self-healing sweep (#166): orphaned batch stashes
        // resume their whole-audio pass; empty sessions with findable audio
        // get a repair job. No stored "processing" claim survives without a
        // live job behind it.
        if let healer = coordinator.transcriptHealer {
            Task(priority: .background) {
                await healer.sweep()
            }
        }
    }

    // MARK: - Polling Loop

    /// Call from a `.task` modifier to start the polling loop. Adaptive
    /// cadence (#142): 250 ms while anything is in flight, 2 s heartbeat
    /// when fully idle — a transition that begins while idle is picked up
    /// within one heartbeat and the loop speeds up.
    func runPollingLoop(settings: AppSettings) async {
        refreshState(settings: settings)
        synchronizeDerivedState(settings: settings)

        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)

            // Poll batch engine status (actor-isolated). Status is a
            // projection only (#166): the Preparing face's percent and the
            // poll cadence read it, while every completion consequence —
            // enrichment, summary reset, history reload, retries — lives in
            // `TranscriptHealer`, which acknowledges terminal statuses back
            // to idle as it settles each job.
            if let engine = coordinator.batchEngine {
                let status = await engine.status
                let importing = await engine.isImporting
                if status != coordinator.batchStatus || importing != coordinator.batchIsImporting {
                    coordinator.batchStatus = status
                    coordinator.batchIsImporting = importing
                }
            }

            refreshState(settings: settings)
            synchronizeDerivedState(settings: settings)
        }
    }

    /// 250 ms while a session is live (running engine or an in-flight
    /// start/stop phase), the batch engine is busy, or an external command
    /// (`lore://` deep link) awaits pickup — a remote start must not wait
    /// out the 2 s heartbeat, that widens the lost-audio window 8×.
    /// 2 s otherwise. Internal for tests.
    var pollInterval: Duration {
        let busy = state.isRunning
            || state.sessionPhase != .idle
            || state.batchStatus != .idle
            || state.batchIsImporting
            || coordinator.pendingExternalCommand != nil
        return busy ? .milliseconds(250) : .seconds(2)
    }

    // MARK: - Session Actions

    func startSession(settings: AppSettings) {
        // The duplicate-start guard lives at the dispatch chokepoint
        // (AppCoordinator.handle); mirrored here so a rejected start does
        // no side work.
        guard coordinator.canStartCapture else { return }
        coordinator.handle(.userStarted(.manual()), settings: settings)
    }

    func stopSession(settings: AppSettings) {
        // Bounce guard (ghost recording): the header button flips to "Stop"
        // the instant coordinator.state changes — before the session exists
        // on disk. A stop in that window is the second press of the same
        // interaction that started the recording; drop it. Once the session
        // is established, stops pass through (and the lifecycle chain
        // serializes them behind the start).
        if coordinator.state != .idle && _currentSessionID == nil { return }
        coordinator.handle(.userStopped, settings: settings)
    }

    /// Suspend capture without ending the session (#153).
    ///
    /// `isCapturing`, not `isRunning`: the latter is set the moment a start
    /// commits, so a session still downloading its model would accept a pause
    /// and leave the user in a paused banner over an engine that then starts
    /// recording. The state guard itself is the machine's job — a pause from
    /// anywhere but `.recording` is already a no-op there.
    func pauseSession(settings: AppSettings) {
        guard coordinator.transcriptionEngine?.isCapturing == true else { return }
        coordinator.handle(.userPaused(.userRequest), settings: settings)
    }

    func resumeSession(settings: AppSettings) {
        coordinator.handle(.userResumed, settings: settings)
    }

    func confirmDownloadAndStart(settings: AppSettings) {
        coordinator.transcriptionEngine?.downloadConfirmed = true
        if coordinator.canStartCapture {
            startSession(settings: settings)
        } else if case .recording = coordinator.state,
                  coordinator.transcriptionEngine?.isRunning != true {
            // A session is already underway with the engine parked at the
            // model-download gate (Start was pressed before the model
            // existed). Continue that session: download and start the engine
            // directly — a new lifecycle start would be rejected at the
            // chokepoint. Runs on the lifecycle chain so a Stop during the
            // download finalizes cleanly behind it.
            //
            // `.recording` specifically, never "not idle" (#153): a paused
            // session also has a stopped engine, and routing it through
            // `startEngine` would re-run the whole capture bring-up under a
            // pause. The recorder itself is safe either way since #177 — a
            // second arm for the same meeting keeps the running tracks rather
            // than wiping the anchors and truncating the audio.
            coordinator.enqueueLifecycleEffect { [self] in
                await startEngine(settings: settings)
            }
        }
    }

    func toggleMicMute() {
        guard let engine = coordinator.transcriptionEngine, engine.isRunning else { return }
        engine.isMicMuted.toggle()
        liveLog.debug("mic mute -> \(engine.isMicMuted ? "on" : "off", privacy: .public)")
    }

    // MARK: - External Commands

    func handlePendingExternalCommandIfPossible(settings: AppSettings, showPastMeetings: (() -> Void)?) {
        guard let request = coordinator.pendingExternalCommand else { return }
        let handled: Bool

        switch request.command {
        case .startSession:
            guard coordinator.transcriptionEngine != nil else { return }
            if coordinator.isPaused {
                // "Make it record" is the intent behind a remote start, and on
                // a paused session that is a resume (#153) — starting is
                // rejected at the chokepoint, so treating the two alike would
                // consume the command and do nothing.
                resumeSession(settings: settings)
            } else if !state.isRunning {
                startSession(settings: settings)
            }
            handled = true
        case .stopSession:
            // The session, not the engine (#153): while paused the engine is
            // down, and gating on it would leave a `lore://stop` pending
            // forever — the request is only cleared once handled.
            guard coordinator.state.isLive else { return }
            stopSession(settings: settings)
            handled = true
        case .openNotes(let sessionID):
            coordinator.queueSessionSelection(sessionID)
            showPastMeetings?()
            handled = true
        }

        if handled {
            coordinator.completeExternalCommand(request.id)
        }
    }

    // MARK: - Utterance Ingestion (migrated from ContentView)

    private func handleNewUtterance(_ last: Utterance, settings: AppSettings) {
        container.detectionController?.noteUtterance()

        if settings.enableTranscriptRefinement, let engine = coordinator.refinementEngine {
            Task {
                await engine.refine(last)
            }
        }

        let sessionID = currentSessionID
        if last.speaker.isRemote {
            Task {
                await coordinator.sessionRepository.appendLiveUtterance(
                    sessionID: sessionID ?? "",
                    utterance: last,
                    metadata: LiveUtteranceMetadata(
                        utteranceID: last.id,
                        transcriptStore: coordinator.transcriptStore,
                        isDelayed: true
                    )
                )
            }
        } else {
            Task {
                await coordinator.sessionRepository.appendLiveUtterance(
                    sessionID: sessionID ?? "",
                    utterance: last
                )
            }
        }
    }

    /// The current session ID from the repository.
    private var currentSessionID: String? {
        // This is captured at start time and held for the session lifetime.
        _currentSessionID
    }
    private var _currentSessionID: String?

    /// The active session's ID for collaborators outside the controller
    /// (Ask Lore chat persistence, #60). Nil once finalization completes.
    var activeSessionID: String? { _currentSessionID }

    private func handleNewUtterances(startingAt startIndex: Int, settings: AppSettings) {
        let utterances = coordinator.transcriptStore.utterances
        guard startIndex < utterances.count else { return }

        for utterance in utterances[startIndex...] {
            handleNewUtterance(utterance, settings: settings)
        }
    }

    // MARK: - Transcription Lifecycle (migrated from AppCoordinator)

    func startTranscription(metadata: MeetingMetadata, settings: AppSettings?) async {
        // Live capture owns the model now. The healer suspends its queue and
        // re-queues the running job uncharged (#166) — preemption is not
        // failure; the pass resumes after the meeting ends.
        if let healer = coordinator.transcriptHealer {
            await healer.suspend()
        } else if let batchEngine = coordinator.batchEngine {
            await batchEngine.cancel()
        }

        coordinator.lastEndedSession = nil
        coordinator.lastStorageError = nil
        coordinator.transcriptStore.clear()

        await coordinator.sessionRepository.setWriteErrorHandler { [weak coordinator] message in
            Task { @MainActor [weak coordinator] in
                coordinator?.lastStorageError = message
            }
        }

        // Freeze template choice at start time
        if let template = coordinator.selectedTemplate {
            coordinator.sessionTemplateSnapshot = coordinator.templateStore.snapshot(of: template)
        } else if let generic = coordinator.templateStore.template(for: TemplateStore.genericID) {
            coordinator.sessionTemplateSnapshot = coordinator.templateStore.snapshot(of: generic)
        } else {
            coordinator.sessionTemplateSnapshot = nil
        }

        // Configure notes folder for mirroring
        if let settings {
            let notesURL = URL(fileURLWithPath: settings.notesFolderPath)
            await coordinator.sessionRepository.setNotesFolderPath(notesURL)
        }

        let templateID = coordinator.selectedTemplate?.id
        let handle = await coordinator.sessionRepository.startSession(
            config: SessionStartConfig(
                templateID: templateID,
                templateSnapshot: coordinator.sessionTemplateSnapshot,
                // Readable default name from the recording start (#58);
                // rename replaces it, nothing regenerates it later.
                title: SessionIndex.defaultTitle(startedAt: metadata.startedAt)
            )
        )
        _currentSessionID = handle.sessionID

        if let settings {
            await startEngine(settings: settings)
        }
    }

    /// Suspend / continue capture for the paused state (#153). Both are
    /// dispatched on the lifecycle chain by `AppCoordinator`, so a stop
    /// enqueued behind either one runs after it and finalizes a settled
    /// engine.
    func pauseCapture() async {
        await coordinator.transcriptionEngine?.pause()
    }

    func resumeCapture() async {
        guard let engine = coordinator.transcriptionEngine else { return }
        await engine.resume()
        if !engine.isCapturing {
            // The resume did not bring capture back. Return the session to
            // paused so every surface keeps saying "paused" — with the
            // engine's error beside it — instead of a red "Recording" banner
            // over a dead mic. The state the user is left in is definite, and
            // Resume is still there to try again.
            coordinator.handle(.userPaused(.resumeFailed))
        }
    }

    /// Wire the audio recorder and start the capture engine with the current
    /// settings. Tail of `startTranscription`; also used by
    /// `confirmDownloadAndStart` to continue a session whose engine was
    /// parked at the model-download gate.
    private func startEngine(settings: AppSettings) async {
        // Decided first, assigned once, after the await below: nilling the
        // engine's recorder up front would leave it without one across an
        // actor hop, which is exactly the window a re-entry here lands in.
        let recorder: AudioRecorder?
        if settings.saveAudioRecording || settings.enableBatchRefinement {
            if let sessionID = _currentSessionID {
                // The tracks are the meeting's from the first buffer (#177).
                let trackDirectory = await coordinator.sessionRepository
                    .prepareAudioDirectory(sessionID: sessionID)
                coordinator.audioRecorder?.startSession(id: sessionID, trackDirectory: trackDirectory)
                recorder = coordinator.audioRecorder
            } else {
                // No session id, no owner for the audio — so this meeting
                // records none. Traced: audio the user asked for and never got
                // must not be a silent branch.
                DiagStore.record(.recordingUnowned)
                liveLog.error("no session id at engine start — this meeting records no audio")
                recorder = nil
            }
        } else {
            recorder = nil
        }
        coordinator.transcriptionEngine?.audioRecorder = recorder

        await coordinator.transcriptionEngine?.start()
    }

    func finalizeCurrentSession(settings: AppSettings?) async {
        // Bind this finalize to the session that was current when it began —
        // a finalize that outlives its timeout (chain dropped, new session
        // started) must not touch the later session.
        let entrySessionID = _currentSessionID

        // 1. Drain audio buffers
        await coordinator.transcriptionEngine?.finalize()

        // 1b. Drain pending refinements
        if let settings, settings.enableTranscriptRefinement {
            await coordinator.refinementEngine?.drain(timeout: .seconds(5))
        }

        // 2. Drain delayed JSONL writes
        await coordinator.sessionRepository.awaitPendingWrites()

        // 3. Build finalization metadata
        let sessionID: String
        if let id = entrySessionID {
            sessionID = id
        } else if let id = await coordinator.sessionRepository.getCurrentSessionID() {
            sessionID = id
        } else {
            // Stop raced ahead of session creation — the lifecycle chain in
            // AppCoordinator makes this unreachable, but belt-and-braces: the
            // engine is already torn down above (step 1), so it can never keep
            // capturing after the state returns to idle, and there is no
            // session to finalize or auto-select. The healer still resumes —
            // its queue must never stay suspended past the recording (#166).
            coordinator.sessionTemplateSnapshot = nil
            coordinator.transcriptHealer?.resume()
            return
        }
        let utterancesSnapshot = coordinator.transcriptStore.utterances
        let utteranceCount = utterancesSnapshot.count

        let meetingAppName: String?
        if case .ending(let metadata) = coordinator.state {
            meetingAppName = metadata.detectionContext?.meetingApp?.name
        } else {
            meetingAppName = nil
        }

        // Nil-propagation is live: `AppCoordinator.handle(_:settings:)` defaults
        // settings to nil, and a stop dispatched that way records engine: nil.
        let engineName = settings != nil ? ParakeetBackend.engineName : nil
        let transcriptionLanguage: String? = {
            guard let locale = settings?.transcriptionLocale, !locale.isEmpty else { return nil }
            return locale
        }()

        // 4. Finalize: closes file handle, backfills refined text, writes
        //    session.json (title preserved), returns the index for UI state.
        let index = await coordinator.sessionRepository.finalizeSession(
            sessionID: sessionID,
            metadata: SessionFinalizeMetadata(
                endedAt: Date(),
                utteranceCount: utteranceCount,
                language: transcriptionLanguage,
                meetingApp: meetingAppName,
                engine: engineName,
                templateSnapshot: coordinator.sessionTemplateSnapshot,
                utterances: utterancesSnapshot
            )
        )

        // 5. Handle audio recording. The tracks are already inside this
        //    meeting (#177), so nothing moves or is copied here. Every call
        //    names the session, exactly as the delete below does: a finalize
        //    that outlived its timeout reaches this line with the recorder
        //    possibly armed for a LATER meeting, and exporting or closing that
        //    one would merge another meeting's audio and leave the running
        //    recording writing nothing.
        if let settings, let recorder = coordinator.audioRecorder {
            if settings.saveAudioRecording {
                await recorder.exportMerged(for: sessionID)
            }
            await recorder.finishTracks(for: sessionID)
            if !settings.enableBatchRefinement {
                // No batch pass, so nothing will read the tracks again.
                await coordinator.sessionRepository.cleanupBatchAudio(sessionID: sessionID)
            }
        }

        // 6. Update UI state + refresh history
        coordinator.lastEndedSession = index
        coordinator.sessionTemplateSnapshot = nil
        // Only clear if it is still ours — a finalize resuming after its
        // timeout must not null a newer session's ID.
        if _currentSessionID == sessionID { _currentSessionID = nil }
        await coordinator.loadHistory()

        // 7. Enrich on-device (#107) — unless a batch pass is about to
        //    replace the transcript, in which case enrichment waits for the
        //    healer's completion path. Detached: never blocks finalization.
        let batchWillRun = settings?.enableBatchRefinement == true
            && coordinator.transcriptHealer != nil
        if !batchWillRun, let engine = coordinator.enrichmentEngine {
            let endedSessionID = sessionID
            Task.detached(priority: .utility) {
                await engine.enrichIfNeeded(sessionID: endedSessionID)
            }
        }

        // 8. Queue the whole-audio pass (#109) at the head of the healer's
        //    queue, then let dispatch continue either way — the queue was
        //    suspended for the whole recording.
        if let settings, settings.enableBatchRefinement, let healer = coordinator.transcriptHealer {
            // Fresh marker (MREV-39): persisted so an unseen processed
            // meeting stays marked across relaunch; cleared when viewed.
            await coordinator.sessionRepository.markSessionUnviewed(sessionID: sessionID)
            healer.enqueueMeetingBatch(sessionID: sessionID)
        }
        coordinator.transcriptHealer?.resume()
    }

    func discardSession() async {
        coordinator.transcriptionEngine?.stop()
        coordinator.transcriptStore.clear()
        let discardedSessionID = _currentSessionID
        _currentSessionID = nil

        if let discardedSessionID {
            // Close this meeting's tracks first, so no queued anchor write can
            // land after the delete. Both calls name the session: the delete
            // never goes by the recorder's memory of what it last recorded,
            // and the close never touches a recorder a later meeting has
            // already armed for itself.
            await coordinator.audioRecorder?.finishTracks(for: discardedSessionID)
            await coordinator.sessionRepository.cleanupBatchAudio(sessionID: discardedSessionID)
        }
        await coordinator.sessionRepository.endSession()

        // The healer was suspended for the recording (#166); a discarded
        // session queues nothing, but dispatch must continue. Last, not first:
        // until its audio is gone this session still looks like a stash with
        // no final transcript — the shape `ensure`/`sweep` dispatch on — and it
        // stopped being the live session they exclude the moment the id above
        // was cleared.
        coordinator.transcriptHealer?.resume()
    }

    // MARK: - State Refresh

    /// Rebuilds the state snapshot; publishes only when it differs (#142).
    /// Internal for tests.
    @MainActor
    func refreshState(settings: AppSettings) {
        var next = LiveSessionState()
        next.isRunning = coordinator.transcriptionEngine?.isRunning ?? false
        next.isCapturing = coordinator.transcriptionEngine?.isCapturing ?? false
        next.sessionPhase = coordinator.state
        next.audioLevel = next.isRunning ? (coordinator.transcriptionEngine?.audioLevel ?? 0) : 0
        next.liveTranscript = coordinator.transcriptStore.utterances
        next.volatileYouText = coordinator.transcriptStore.volatileYouText
        next.volatileThemText = coordinator.transcriptStore.volatileThemText
        next.batchStatus = coordinator.batchStatus
        next.batchIsImporting = coordinator.batchIsImporting
        next.lastEndedSession = coordinator.lastEndedSession
        next.statusMessage = coordinator.transcriptionEngine?.assetStatus
        next.errorMessage = coordinator.transcriptionEngine?.lastError
        next.needsDownload = coordinator.transcriptionEngine?.needsModelDownload ?? false
        next.downloadProgress = coordinator.transcriptionEngine?.downloadProgress
        next.showLiveTranscript = settings.showLiveTranscript
        next.isMicMuted = coordinator.transcriptionEngine?.isMicMuted ?? false

        if next != state {
            state = next
        }
    }

    // MARK: - Derived State Synchronization

    /// Navigates the unified window to Meetings → Past — set by the view.
    var showPastMeetings: (() -> Void)?

    @MainActor
    private func synchronizeDerivedState(settings: AppSettings) {
        let currentState = state

        if settings.notesFolderPath != observedNotesFolderPath {
            observedNotesFolderPath = settings.notesFolderPath
            let url = URL(fileURLWithPath: settings.notesFolderPath)
            Task {
                await coordinator.sessionRepository.setNotesFolderPath(url)
            }
            coordinator.audioRecorder?.updateDirectory(url)
        }

        if settings.inputDeviceID != observedInputDeviceID {
            observedInputDeviceID = settings.inputDeviceID
            if currentState.isRunning {
                Task {
                    coordinator.transcriptionEngine?.restartMic(inputDeviceID: settings.inputDeviceID)
                }
            }
        }

        let utteranceCount = currentState.liveTranscript.count
        if utteranceCount > observedUtteranceCount {
            handleNewUtterances(startingAt: observedUtteranceCount, settings: settings)
        }
        observedUtteranceCount = utteranceCount

        let pendingExternalCommandID = coordinator.pendingExternalCommand?.id
        if pendingExternalCommandID != observedPendingExternalCommandID {
            observedPendingExternalCommandID = pendingExternalCommandID
            handlePendingExternalCommandIfPossible(settings: settings, showPastMeetings: showPastMeetings)
        }
    }
}
