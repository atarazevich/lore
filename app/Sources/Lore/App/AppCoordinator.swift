import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.lore.app", category: "MeetingLifecycle")

/// Slim coordinator that owns the meeting lifecycle state machine and all shared
/// cross-cutting state (session history, external command queue, detection event loop).
///
/// **What lives here:**
/// - `state` / `handle()` / `performSideEffects()` — canonical MeetingState machine
/// - `sessionHistory` / `lastEndedSession` — shared observable state consumed by multiple views
/// - External command queue — bridges deep links and menu-bar actions to the live session
/// - Detection event loop — maps MeetingDetectionController events to state machine events
/// - Service references — constructor-injected stores and lazily-set engines
///
/// Side effects are delegated to `LiveSessionController`; this class never touches audio
/// or disk directly.
@Observable
@MainActor
final class AppCoordinator {
    @ObservationIgnored private let _sessionRepository: SessionRepository
    nonisolated var sessionRepository: SessionRepository { _sessionRepository }

    @ObservationIgnored private let _templateStore: TemplateStore
    nonisolated var templateStore: TemplateStore { _templateStore }

    @ObservationIgnored private let _transcriptStore: TranscriptStore
    nonisolated var transcriptStore: TranscriptStore { _transcriptStore }

    @ObservationIgnored nonisolated(unsafe) private var _selectedTemplate: MeetingTemplate?
    var selectedTemplate: MeetingTemplate? {
        get { access(keyPath: \.selectedTemplate); return _selectedTemplate }
        set { withMutation(keyPath: \.selectedTemplate) { _selectedTemplate = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _lastEndedSession: SessionIndex?
    var lastEndedSession: SessionIndex? {
        get { access(keyPath: \.lastEndedSession); return _lastEndedSession }
        set { withMutation(keyPath: \.lastEndedSession) { _lastEndedSession = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _pendingExternalCommand: ExternalCommandRequest?
    var pendingExternalCommand: ExternalCommandRequest? {
        get { access(keyPath: \.pendingExternalCommand); return _pendingExternalCommand }
        set { withMutation(keyPath: \.pendingExternalCommand) { _pendingExternalCommand = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _requestedSessionSelectionID: String?
    var requestedSessionSelectionID: String? {
        get { access(keyPath: \.requestedSessionSelectionID); return _requestedSessionSelectionID }
        set { withMutation(keyPath: \.requestedSessionSelectionID) { _requestedSessionSelectionID = newValue } }
    }

    /// Actively capturing. Deliberately false while `.paused` (#153): every
    /// surface that pulses, meters or says "Recording" reads this, and a
    /// paused session is not recording.
    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Capture suspended, session still open (#153).
    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    @ObservationIgnored nonisolated(unsafe) private var _sessionHistory: [SessionIndex] = []
    private(set) var sessionHistory: [SessionIndex] {
        get { access(keyPath: \.sessionHistory); return _sessionHistory }
        set { withMutation(keyPath: \.sessionHistory) { _sessionHistory = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _state: MeetingState = .idle
    private(set) var state: MeetingState {
        get { access(keyPath: \.state); return _state }
        set { withMutation(keyPath: \.state) { _state = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _lastStorageError: String?
    var lastStorageError: String? {
        get { access(keyPath: \.lastStorageError); return _lastStorageError }
        set { withMutation(keyPath: \.lastStorageError) { _lastStorageError = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _batchStatus: BatchTranscriptionEngine.Status = .idle
    var batchStatus: BatchTranscriptionEngine.Status {
        get { access(keyPath: \.batchStatus); return _batchStatus }
        set { withMutation(keyPath: \.batchStatus) { _batchStatus = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _batchIsImporting: Bool = false
    var batchIsImporting: Bool {
        get { access(keyPath: \.batchIsImporting); return _batchIsImporting }
        set { withMutation(keyPath: \.batchIsImporting) { _batchIsImporting = newValue } }
    }

    var transcriptionEngine: TranscriptionEngine?
    var refinementEngine: TranscriptRefinementEngine?
    var audioRecorder: AudioRecorder?
    var batchEngine: BatchTranscriptionEngine?
    /// The transcript self-healing queue (#166) — the only dispatcher into
    /// `batchEngine`: end-of-meeting pass, launch sweep, open-summoned
    /// repairs, imports, quiet retries.
    var transcriptHealer: TranscriptHealer?
    /// Meeting auto-enrichment (#107). Live mode only — nil in UI tests, so
    /// every trigger is a no-op there.
    var enrichmentEngine: MeetingEnrichmentEngine?

    // MARK: - Shared Backend Cache

    let sharedBackendCache = SharedBackendCache()

    // MARK: - Dictation

    let dictationCoordinator = DictationCoordinator()
    let hotkeyManager = HotkeyManager()
    let dictationIndicator = DictationIndicatorManager()

    // MARK: - Read Aloud (#105)

    let readAloudController = ReadAloudController()
    let readAloudPanel = ReadAloudPanelManager()

    /// Live health readiness (#83). Set once dictation is wired (it needs the
    /// hotkey tap's state); the shell footer and health panel read it. Nil in
    /// UI-test mode, where the footer falls back to the version string.
    var healthMonitor: HealthMonitor?

    /// The template snapshot frozen at session start (not stop).
    var sessionTemplateSnapshot: TemplateSnapshot?

    /// Guard against finalization hanging forever. Injectable so tests can
    /// shorten the 30s production value.
    private var finalizationTimeoutTask: Task<Void, Never>?
    @ObservationIgnored var finalizationTimeout: Duration = .seconds(30)

    /// Serial chain for lifecycle side effects (start / stop / discard).
    /// Dispatch order is preserved: a stop enqueued behind an in-flight start
    /// awaits the start's session setup first, so finalization can never run
    /// before the session exists and leave the engine capturing detached from
    /// any session (the "ghost recording" race).
    @ObservationIgnored private var lifecycleEffectChain: Task<Void, Never>?

    /// Bumped when `.finalizationTimeout` drops the chain: effects that were
    /// queued (but not started) before the drop are invalidated and never run.
    @ObservationIgnored private var lifecycleEpoch = 0

    /// Bumped per `.userStopped` dispatch. Binds each finalize effect and its
    /// timeout timer to the stop that created them, so a finalize that
    /// outlives its timeout cannot disturb a later stop (cancel its timer or
    /// flip its `.ending` to `.idle`).
    @ObservationIgnored private var stopGeneration = 0

    /// Retained reference to the active settings for side effects.
    var activeSettings: AppSettings?

    /// The live session controller that handles all session side effects.
    weak var liveSessionController: LiveSessionController?

    /// Task consuming detection controller events.
    private var detectionEventTask: Task<Void, Never>?

    /// The controller feeding that task. Held weakly (AppContainer owns it) so
    /// pause/resume can suspend and restart the silence-timeout monitor (#153).
    private weak var detectionController: MeetingDetectionController?

    init(
        sessionRepository: SessionRepository = SessionRepository(),
        templateStore: TemplateStore = TemplateStore(),
        transcriptStore: TranscriptStore = TranscriptStore()
    ) {
        self._sessionRepository = sessionRepository
        self._templateStore = templateStore
        self._transcriptStore = transcriptStore
    }


    // MARK: - State Machine

    /// True when a new capture session may start: lifecycle state idle AND
    /// the engine itself not capturing — the two truth sources whose
    /// divergence produced the ghost recording (#42).
    var canStartCapture: Bool {
        state == .idle && transcriptionEngine?.isRunning != true
    }

    /// Drive the meeting lifecycle through the state machine, then dispatch side effects.
    func handle(_ event: MeetingEvent, settings: AppSettings? = nil) {
        let resolvedSettings = settings ?? activeSettings

        // Dispatch chokepoint for every start surface (UI, menu bar, hotkey,
        // detection): never begin a session while one is active by either
        // truth source.
        if case .userStarted = event, !canStartCapture {
            logger.info("Start ignored: session already active (state not idle, or engine still capturing)")
            return
        }

        let oldState = state
        state = transition(from: oldState, on: event)

        // Only dispatch side effects when the state actually changed
        guard state != oldState else { return }

        performSideEffects(for: event, settings: resolvedSettings)
    }

    // MARK: - Side Effects

    private func performSideEffects(for event: MeetingEvent, settings: AppSettings?) {
        switch event {
        case .userStarted(let metadata):
            enqueueLifecycleEffect { [self] in
                await liveSessionController?.startTranscription(metadata: metadata, settings: settings)
            }

        case .userPaused(let cause):
            DiagStore.record(cause == .resumeFailed ? .sessionResumeFailed : .sessionPaused)
            // The silence-timeout monitor is suspended for the duration of the
            // pause (#153): a paused meeting is silent on purpose, and letting
            // the timer run would auto-finalize the session behind the user's
            // back. It restarts fresh on resume.
            detectionController?.stopSilenceMonitoring()
            enqueueLifecycleEffect { [self] in
                await liveSessionController?.pauseCapture()
            }

        case .userResumed:
            DiagStore.record(.sessionResumed)
            enqueueLifecycleEffect { [self] in
                await liveSessionController?.resumeCapture()
            }
            // Only auto-detected sessions ever had a silence monitor; restart
            // it for those, with a fresh clock (#153).
            if case .appLaunched = state.metadata?.detectionContext?.signal {
                detectionController?.startSilenceMonitoring()
            }

        case .userStopped:
            stopGeneration += 1
            let generation = stopGeneration
            enqueueLifecycleEffect { [self] in
                // Arm the timeout only when finalization actually begins — a
                // finalize queued behind a slow start (e.g. model download)
                // must not trip a spurious timeout, which would transiently
                // recreate the ghost condition (engine up while state idle).
                armFinalizationTimeout(generation: generation)
                await liveSessionController?.finalizeCurrentSession(settings: settings)
                completeFinalization(generation: generation)
            }

        case .userDiscarded:
            enqueueLifecycleEffect { [self] in
                await liveSessionController?.discardSession()
            }

        case .finalizationComplete:
            finalizationTimeoutTask?.cancel()
            finalizationTimeoutTask = nil

        case .finalizationTimeout:
            finalizationTimeoutTask = nil
            // A hung finalize must not queue every future lifecycle effect
            // until relaunch: drop the chain. Queued-but-unstarted effects
            // are invalidated via the epoch; the hung effect itself cannot
            // be killed, but its completion is generation-guarded.
            lifecycleEpoch += 1
            lifecycleEffectChain = nil
        }
    }

    /// Run a lifecycle side effect after all previously dispatched ones
    /// finish. Internal (not private) as a seam for lifecycle tests.
    func enqueueLifecycleEffect(_ operation: @escaping @MainActor () async -> Void) {
        let epoch = lifecycleEpoch
        let previous = lifecycleEffectChain
        lifecycleEffectChain = Task { @MainActor [self] in
            await previous?.value
            guard epoch == lifecycleEpoch else { return }
            await operation()
        }
    }

    private func armFinalizationTimeout(generation: Int) {
        finalizationTimeoutTask = Task { [self] in
            try? await Task.sleep(for: finalizationTimeout)
            // A stale timer (its stop was superseded) must not force-idle a
            // later stop's finalization.
            guard !Task.isCancelled, generation == stopGeneration else { return }
            handle(.finalizationTimeout)
        }
    }

    /// Complete a finalize effect for `generation`. Stale generations no-op:
    /// a finalize that outlived its timeout (chain dropped, later sessions
    /// possibly started and stopped) must not cancel a later stop's timer or
    /// flip a later stop's `.ending` to `.idle`. Internal for lifecycle tests.
    func completeFinalization(generation: Int) {
        guard generation == stopGeneration else { return }
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        handle(.finalizationComplete)
    }

    // MARK: - History

    /// Load session history from sidecars (lightweight index only).
    func loadHistory() async {
        sessionHistory = await sessionRepository.listSessions()
    }

    func queueExternalCommand(_ command: ExternalCommand) {
        pendingExternalCommand = ExternalCommandRequest(command: command)
    }

    func completeExternalCommand(_ requestID: UUID) {
        guard pendingExternalCommand?.id == requestID else { return }
        pendingExternalCommand = nil
    }

    func queueSessionSelection(_ sessionID: String?) {
        requestedSessionSelectionID = sessionID
    }

    func consumeRequestedSessionSelection() -> String? {
        defer { requestedSessionSelectionID = nil }
        return requestedSessionSelectionID
    }

    // MARK: - Detection Event Loop

    /// Start consuming events from the detection controller's stream.
    /// Maps detection events to state machine events.
    func startDetectionEventLoop(_ controller: MeetingDetectionController) {
        activeSettings = controller.activeSettings
        detectionController = controller
        detectionEventTask?.cancel()
        detectionEventTask = Task { [weak self] in
            for await event in controller.events {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .accepted(let metadata):
                    // Start silence monitoring for auto-detected sessions
                    if case .appLaunched(let app) = metadata.detectionContext?.signal {
                        controller.startSilenceMonitoring()
                        controller.startAppExitMonitoring(bundleID: app.bundleID)
                    }
                    self.handle(.userStarted(metadata), settings: self.activeSettings)
                case .meetingAppExited:
                    // Paused counts: the meeting app is gone, so the session is
                    // over whether or not capture was suspended (#153).
                    if self.state.isLive,
                       case .appLaunched = self.state.metadata?.detectionContext?.signal {
                        controller.stopSilenceMonitoring()
                        controller.stopAppExitMonitoring()
                        self.handle(.userStopped)
                    }
                case .silenceTimeout:
                    // `.recording` only: a paused session is exempt from the
                    // silence timeout by construction (its monitor is stopped
                    // at pause), and this guard says so a second time (#153).
                    if case .recording = self.state {
                        controller.stopSilenceMonitoring()
                        controller.stopAppExitMonitoring()
                        self.handle(.userStopped)
                    }
                case .systemSleep:
                    // Sleeping while paused finalizes, exactly as sleeping
                    // while recording does — the machine is going away and an
                    // open session must not survive it (#153).
                    if self.state.isLive {
                        controller.stopSilenceMonitoring()
                        controller.stopAppExitMonitoring()
                        self.handle(.userStopped)
                    }
                case .notAMeeting, .dismissed, .timeout:
                    break
                }
            }
        }
    }

    /// Stop consuming detection events.
    func stopDetectionEventLoop() {
        detectionEventTask?.cancel()
        detectionEventTask = nil
        detectionController = nil
    }
}
