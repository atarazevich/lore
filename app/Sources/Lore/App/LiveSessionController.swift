import Foundation
import os
import Observation
import CoreAudio

private let liveLog = Logger(subsystem: "com.lore.app", category: "LiveSession")

/// Published state for the live session, projected by ContentView.
struct LiveSessionState {
    var isRunning: Bool = false
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
    /// Tracks the session ID we last handled a batch completion for,
    /// preventing the auto-dismiss → re-poll cycle from re-triggering the history reload.
    private var lastHandledBatchSessionID: String?

    init(coordinator: AppCoordinator, container: AppContainer) {
        self.coordinator = coordinator
        self.container = container
    }

    // MARK: - Initialization

    /// One-time setup tasks called when the view first appears.
    func performInitialSetup() async {
        await coordinator.sessionRepository.purgeRecentlyDeleted()
    }

    // MARK: - Polling Loop

    /// Call from a `.task` modifier to start the 250ms polling loop.
    func runPollingLoop(settings: AppSettings) async {
        refreshState(settings: settings)
        synchronizeDerivedState(settings: settings)

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))

            // Poll batch engine status (actor-isolated)
            if let engine = coordinator.batchEngine {
                let status = await engine.status
                let importing = await engine.isImporting
                if status != .idle || coordinator.batchStatus != .idle {
                    coordinator.batchStatus = status
                    coordinator.batchIsImporting = importing

                    if case .completed(let sid) = status, lastHandledBatchSessionID != sid {
                        lastHandledBatchSessionID = sid
                        await coordinator.loadHistory()

                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            if case .completed = coordinator.batchStatus {
                                coordinator.batchStatus = .idle
                            }
                        }
                    }
                }
            }

            refreshState(settings: settings)
            synchronizeDerivedState(settings: settings)
        }
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

    func confirmDownloadAndStart(settings: AppSettings) {
        coordinator.transcriptionEngine?.downloadConfirmed = true
        if coordinator.canStartCapture {
            startSession(settings: settings)
        } else if coordinator.state != .idle, coordinator.transcriptionEngine?.isRunning != true {
            // A session is already underway with the engine parked at the
            // model-download gate (Start was pressed before the model
            // existed). Continue that session: download and start the engine
            // directly — a new lifecycle start would be rejected at the
            // chokepoint. Runs on the lifecycle chain so a Stop during the
            // download finalizes cleanly behind it.
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
            if !state.isRunning {
                startSession(settings: settings)
            }
            handled = true
        case .stopSession:
            guard state.isRunning else { return }
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
        if let batchEngine = coordinator.batchEngine {
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

    /// Wire the audio recorder and start the capture engine with the current
    /// settings. Tail of `startTranscription`; also used by
    /// `confirmDownloadAndStart` to continue a session whose engine was
    /// parked at the model-download gate.
    private func startEngine(settings: AppSettings) async {
        if settings.saveAudioRecording || settings.enableBatchRefinement {
            coordinator.audioRecorder?.startSession()
            coordinator.transcriptionEngine?.audioRecorder = coordinator.audioRecorder
        } else {
            coordinator.transcriptionEngine?.audioRecorder = nil
        }

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
            // session to finalize or auto-select.
            coordinator.sessionTemplateSnapshot = nil
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

        // 5. Handle audio recording
        if let settings, let recorder = coordinator.audioRecorder {
            let wantsBatch = settings.enableBatchRefinement
            let wantsExport = settings.saveAudioRecording

            if wantsBatch && wantsExport {
                let tempURLs = recorder.tempFileURLs()
                let anchorsData = recorder.timingAnchors()
                let fm = FileManager.default

                let copiedMic: URL?
                if let micSrc = tempURLs.mic, fm.fileExists(atPath: micSrc.path) {
                    let dst = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("batch_mic_\(sessionID).caf")
                    try? fm.copyItem(at: micSrc, to: dst)
                    copiedMic = dst
                } else {
                    copiedMic = nil
                }

                let copiedSys: URL?
                if let sysSrc = tempURLs.sys, fm.fileExists(atPath: sysSrc.path) {
                    let dst = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("batch_sys_\(sessionID).caf")
                    try? fm.copyItem(at: sysSrc, to: dst)
                    copiedSys = dst
                } else {
                    copiedSys = nil
                }

                await coordinator.sessionRepository.stashAudioForBatch(
                    sessionID: sessionID,
                    micURL: copiedMic,
                    sysURL: copiedSys,
                    anchors: BatchAnchors(
                        micStartDate: anchorsData.micStartDate,
                        sysStartDate: anchorsData.sysStartDate,
                        micAnchors: anchorsData.micAnchors,
                        sysAnchors: anchorsData.sysAnchors
                    )
                )

                await recorder.finalizeRecording()
            } else if wantsBatch {
                let sealed = recorder.sealForBatch()
                await coordinator.sessionRepository.stashAudioForBatch(
                    sessionID: sessionID,
                    micURL: sealed.mic,
                    sysURL: sealed.sys,
                    anchors: BatchAnchors(
                        micStartDate: sealed.micStartDate,
                        sysStartDate: sealed.sysStartDate,
                        micAnchors: sealed.micAnchors,
                        sysAnchors: sealed.sysAnchors
                    )
                )
            } else if wantsExport {
                await recorder.finalizeRecording()
            }
        }

        // 6. Update UI state + refresh history
        coordinator.lastEndedSession = index
        coordinator.sessionTemplateSnapshot = nil
        // Only clear if it is still ours — a finalize resuming after its
        // timeout must not null a newer session's ID.
        if _currentSessionID == sessionID { _currentSessionID = nil }
        await coordinator.loadHistory()

        // 7. Kick off batch transcription if enabled
        if let settings, settings.enableBatchRefinement, let batchEngine = coordinator.batchEngine {
            let batchSessionID = sessionID
            // Fresh marker (MREV-39): persisted so the green dot / processing
            // state survive relaunch mid-batch; cleared when the user views
            // the processed meeting.
            await coordinator.sessionRepository.markSessionUnviewed(sessionID: batchSessionID)
            let notesDir = URL(fileURLWithPath: settings.notesFolderPath)
            let repo = coordinator.sessionRepository
            Task.detached { [batchEngine] in
                await batchEngine.process(
                    sessionID: batchSessionID,
                    sessionRepository: repo,
                    notesDirectory: notesDir
                )
            }
        }
    }

    func discardSession() {
        coordinator.transcriptionEngine?.stop()
        coordinator.audioRecorder?.discardRecording()
        coordinator.transcriptStore.clear()
        _currentSessionID = nil
        Task {
            await coordinator.sessionRepository.endSession()
        }
    }

    // MARK: - State Refresh

    @MainActor
    private func refreshState(settings: AppSettings) {
        var next = LiveSessionState()
        next.isRunning = coordinator.transcriptionEngine?.isRunning ?? false
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

        state = next
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
