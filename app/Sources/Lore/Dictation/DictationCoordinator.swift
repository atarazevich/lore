import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import os

enum UpgradeAction: Sendable {
    case cleanup
    case translate
}

@Observable
@MainActor
final class DictationCoordinator {
    private(set) var state: DictationState = .idle
    private(set) var audioLevel: Float = 0
    private(set) var lastTranscript: String?
    private(set) var lastError: String?
    /// Whether the upgrade panel (C/T buttons) is visible after initial paste.
    private(set) var isUpgradePanelVisible = false
    /// Whether cleanup was already applied (hides [C] button, only shows [T]).
    private(set) var cleanupAlreadyApplied = false
    /// Countdown remaining for upgrade auto-dismiss (seconds). Nil when not showing.
    private(set) var upgradeCountdown: Double?
    /// Pre-paste cleanup mode set during recording via Fn+V/Fn+T.
    private(set) var pendingCleanupMode: UpgradeAction?
    /// True while audio is being buffered before hold is confirmed (pre-buffer phase).
    private(set) var isPreBuffering = false
    /// True when a wireless default input was detected and capture redirected to built-in mic.
    private(set) var bluetoothMicRedirected = false
    /// True when the audio bus reports zero signal (dead mic input).
    private(set) var noSignal = false

    private let log = Logger(subsystem: "com.lore.app", category: "DictationCoordinator")
    private var busConsumerID: UUID?
    private var recordingTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var firstFrameWatchdogTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?
    private var upgradeDismissTask: Task<Void, Never>?
    /// True when a mic error is parked in `.done` while Fn may still be held — it must
    /// stay visible (no auto-hide) until the genuine Fn release starts the grace hide.
    private var micErrorSticky = false
    /// A sticky mic error whose message is still resolving on the HAL queue (#64).
    /// If the Fn release arrives before it lands, `pendingStickyRelease` makes it land
    /// with the grace hide instead of sticking with no dismissal path.
    private var stickyErrorInFlight = false
    private var pendingStickyRelease = false
    private var accumulatedSamples: [Float] = []
    private var converter: AVAudioConverter?
    private let cleanupClient: any CleanupProviding

    private static let minimumSpeechSamples = 8000
    private static let maxChunkSamples = 480_000
    static let upgradePanelDuration: Double = 3.0

    /// User-facing paste-time failure messages (#50). Raw text is still
    /// pasted (DIC-48 fallback unchanged) — these only make the silence visible.
    static let cleanupFailedPastedRaw = "Cleanup failed \u{2014} pasted raw text"
    static let translateFailedPastedRaw = "Translation failed \u{2014} pasted raw text"
    /// Upgrade-key (C/T) failures keep whatever was already pasted.
    static let cleanupFailedKeptText = "Cleanup failed \u{2014} kept pasted text"
    static let translateFailedKeptText = "Translation failed \u{2014} kept pasted text"

    /// Shared audio bus — set by AppDelegate during dictation setup.
    var audioBus: AudioBus?

    /// Read Aloud interplay (#105), wired by the dictation setup. Capture
    /// started (pre-buffer, before the mic opens) → pause playback so zero
    /// TTS output enters the buffer; capture ended (`stopMicCapture`, the one
    /// chokepoint every stop path crosses) → maybe auto-resume. `cancelled`
    /// is true when the gesture never became a recording (a sub-150 ms tap):
    /// not a dictation, so the listener resumes unconditionally.
    var onCaptureStarted: (() -> Void)?
    var onCaptureEnded: ((_ cancelled: Bool) -> Void)?
    /// Whether the current capture gesture was confirmed as a recording —
    /// distinguishes a cancelled tap from a real dictation for `onCaptureEnded`.
    private var captureConfirmed = false

    /// Shared backend cache — set by AppDelegate during dictation setup.
    var backendCache: SharedBackendCache?

    /// Private backend instance for dictation transcription.
    /// Separate from the shared cache to avoid concurrent decoder state mutation
    /// when TranscriptionEngine also transcribes via the shared backend.
    private var ownBackend: (any TranscriptionBackend)?

    /// In-flight build of `ownBackend`, if any. Lets the launch prewarm and a
    /// real first dictation share one load instead of each building a backend.
    private var ownBackendTask: Task<any TranscriptionBackend, Error>?

    /// The current history entry being processed (needed for upgrades).
    private var currentEntryID: UUID?

    /// Monotonic recording-session counter (#104), bumped when a recording is
    /// confirmed and on discard. Mirrors `captureEpoch`, but for the session's
    /// ownership of shared UI state (state/indicator/lastError): a pipeline
    /// whose epoch is stale still finishes — text into history, paste — but
    /// must not stomp the newer session's UI.
    private var sessionEpoch = 0

    /// The newest link in the transcription chain — a dictation pipeline
    /// (stop→save→transcribe→cleanup→paste) or a history retry — paired with
    /// the session epoch it was enqueued under (#104). Coordinator-owned so
    /// the hotkey release-debounce Task's cancellation (the next Fn press)
    /// cannot kill it; one pair so epoch and task cannot desynchronize. A
    /// discard cancels it only when the epoch is the current session's own.
    private var latestTranscription: (epoch: Int, task: Task<Void, Never>)?

    /// The 300ms audio-tail sleep of the in-flight pipeline, separate from
    /// the pipeline Task so a new Fn press can cut the tail short without
    /// cancelling the pipeline itself (#104): `startPreBuffer` cancels it,
    /// finalizes the capture synchronously, and parks the samples in
    /// `cutTailSamples` for the pipeline to pick up.
    private var tailTask: Task<Void, Never>?
    private var cutTailSamples: [Float]?

    /// Enqueue the newest transcription (#104). `work` receives the session
    /// epoch it was enqueued under and the previous link, which it must await
    /// before entering the shared ASR backend — the backend is never entered
    /// by two transcriptions concurrently.
    @discardableResult
    private func enqueueTranscription(
        _ work: @escaping @MainActor (_ epoch: Int, _ previous: Task<Void, Never>?) async -> Void
    ) -> Task<Void, Never> {
        let epoch = sessionEpoch
        let previous = latestTranscription?.task
        let task = Task { await work(epoch, previous) }
        latestTranscription = (epoch: epoch, task: task)
        return task
    }

    /// True while `epoch` still names the newest recording session, i.e. the
    /// caller owns the shared UI state. `nil` = the caller is not
    /// session-scoped (history-row transforms, upgrade keys): always allowed.
    private func isCurrentSession(_ epoch: Int?) -> Bool {
        epoch == nil || epoch == sessionEpoch
    }

    let history: DictationHistory
    var settings: AppSettings?

    /// `history` is injectable so tests can back it with an ephemeral
    /// UserDefaults suite instead of the user's real dictation history;
    /// `cleanupClient` so tests can force LLM failures without the network;
    /// `backend` so tests can drive the chunk loop without the local model.
    init(
        history: DictationHistory = DictationHistory(),
        cleanupClient: any CleanupProviding = CleanupClient(),
        backend: (any TranscriptionBackend)? = nil
    ) {
        self.history = history
        self.cleanupClient = cleanupClient
        self.ownBackend = backend
    }

    /// Start capturing audio silently before hold is confirmed (pre-buffer phase).
    /// State stays .idle — indicator does not show yet.
    func startPreBuffer() {
        guard !isPreBuffering else { return }
        // A previous dictation may still be transcribing (.processing /
        // .loadingModel): its pipeline keeps running in the background (#104).
        if state == .recording {
            // Recording state with the current session's own pipeline
            // enqueued means the pipeline is in its 300ms audio tail: this
            // press is a real new dictation, so cut the tail at the press —
            // finalize the old capture synchronously (before the new one
            // claims the bus) and park the samples for the pipeline (#104).
            // Without a current-session pipeline suspended in its tail
            // (`tailTask` non-nil) this is a live hold — an Fn flag flicker,
            // not a press — and the recording is left alone. The tailTask
            // check also guarantees the parked samples are always picked up:
            // the pipeline is at the tail await, whose next statement reads
            // `cutTailSamples`.
            guard latestTranscription?.epoch == sessionEpoch, let tailTask else { return }
            tailTask.cancel()
            self.tailTask = nil
            stopMicCapture()
            cutTailSamples = accumulatedSamples
            accumulatedSamples.removeAll()
            state = .processing
        }
        guard let settings else {
            log.error("settings not wired — dictation disabled")
            return
        }

        micErrorSticky = false
        stickyErrorInFlight = false
        pendingStickyRelease = false
        accumulatedSamples.removeAll()
        converter = nil
        isPreBuffering = true

        // Microphone permission gate. The common (.authorized) case is a synchronous
        // status read, so it adds no latency to hold-to-talk. Only a first-ever
        // dictation hits the async .notDetermined branch.
        switch MicrophonePermission.status {
        case .authorized:
            captureConfirmed = false
            // Pause Read Aloud before the mic opens — not at hold-confirm,
            // by which point TTS output would already be in the buffer (#105).
            onCaptureStarted?()
            startMicCapture()
            // "Sound on start" (DSET-16, default off): chime at the point
            // capture actually begins (mic live), not on key-down — the
            // denied/undetermined branches never chime.
            if settings.soundOnDictationStart, let sound = NSSound(named: "Pop") {
                sound.volume = 0.4
                sound.play()
            }
            log.debug("pre-buffering started")
        case .denied, .restricted:
            failPreBufferWithMicUnavailableMessage()
        case .notDetermined:
            // Present the system prompt. The triggering hold won't complete (the
            // user is interacting with the prompt); once granted, the next press
            // takes the synchronous .authorized path above.
            isPreBuffering = false
            Task { @MainActor [weak self] in
                let granted = await MicrophonePermission.request()
                guard let self, !granted else { return }
                // The key was released while the OS prompt was up, so use the grace
                // hide directly rather than waiting for a release that already happened.
                self.surfaceMicError(await self.micUnavailableMessage(), hide: .grace)
            }
        @unknown default:
            failPreBuffer(MicrophonePermission.unknownMessage)
        }
    }

    /// How a surfaced mic error should hide.
    private enum MicErrorHide {
        /// Fn may still be held — keep it visible (no timer) until release starts the grace hide.
        case sticky
        /// Fn is already released — start the ~4s grace hide immediately.
        case grace
    }

    /// Abort a pre-buffer that never started capture and surface a held error.
    /// Called only from the synchronous permission branches in `startPreBuffer`, where
    /// the Fn key is still down, so the error stays sticky until release.
    private func failPreBuffer(_ message: String) {
        isPreBuffering = false
        surfaceMicError(message, hide: .sticky)
    }

    /// Same abort, but for the mic-unavailable message, whose device-name lookup hops
    /// to the HAL queue (#64). If Fn is released while the hop is in flight, the error
    /// lands with the grace hide instead of sticking with no dismissal path; a new Fn
    /// press supersedes the in-flight error entirely.
    private func failPreBufferWithMicUnavailableMessage() {
        isPreBuffering = false
        stickyErrorInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let message = await self.micUnavailableMessage()
            guard self.stickyErrorInFlight else { return } // superseded by a new press
            self.stickyErrorInFlight = false
            let hide: MicErrorHide = self.pendingStickyRelease ? .grace : .sticky
            self.pendingStickyRelease = false
            self.surfaceMicError(message, hide: hide)
        }
    }

    /// Show a mic error in the floating indicator. The indicator only renders while
    /// non-idle, so we park in `.done`. A sticky error stays until the Fn release
    /// (`dismissMicErrorAfterRelease`); a grace error hides after a readable ~4s.
    private func surfaceMicError(_ message: String, hide: MicErrorHide) {
        lastError = message
        state = .done
        switch hide {
        case .sticky:
            autoHideTask?.cancel()
            autoHideTask = nil
            micErrorSticky = true
        case .grace:
            micErrorSticky = false
            scheduleAutoHide(after: .seconds(4))
        }
    }

    /// Called by HotkeyManager on a genuine Fn release to begin hiding a sticky mic
    /// error after a readable grace period. No-op unless a sticky error is showing, so
    /// it's safe to call from every release path (locked/hold/tap).
    func dismissMicErrorAfterRelease() {
        // The release raced an in-flight sticky error (#64 review): record it so the
        // error lands with the grace hide instead of persisting with no dismissal path.
        if stickyErrorInFlight {
            pendingStickyRelease = true
            return
        }
        guard micErrorSticky, state == .done else { return }
        micErrorSticky = false
        scheduleAutoHide(after: .seconds(4))
    }

    /// Confirm that the hold gesture was detected — transition to visible recording.
    func confirmRecording() {
        guard isPreBuffering else { return }
        isPreBuffering = false
        // The confirmed recording takes ownership of the shared UI state
        // (#104): a pipeline still finishing an earlier dictation goes stale
        // for state/indicator writes (history update and paste are not
        // gated). Only now, at confirm — an unconfirmed pre-buffer (a tap)
        // must not strip the finishing session's upgrade panel, error row,
        // entry id, or pending auto-hide.
        sessionEpoch += 1
        autoHideTask?.cancel()
        autoHideTask = nil
        upgradeDismissTask?.cancel()
        upgradeDismissTask = nil
        isUpgradePanelVisible = false
        upgradeCountdown = nil
        currentEntryID = nil
        pendingCleanupMode = nil
        lastError = nil
        captureConfirmed = true
        state = .recording
        log.debug("recording confirmed (pre-buffer kept)")
    }

    /// Cancel pre-buffer (user tapped instead of holding).
    func cancelPreBuffer() {
        guard isPreBuffering else { return }
        isPreBuffering = false
        stopMicCapture()
        accumulatedSamples.removeAll()
        log.debug("pre-buffer discarded (tap)")
    }

    /// Stop the current recording. The save→transcribe→paste pipeline runs in
    /// a coordinator-owned Task (#104): the hotkey release-debounce Task that
    /// calls this is cancelled first thing by the next Fn press, and when the
    /// pipeline ran inline there, that press killed the in-flight
    /// transcription and lost the dictation. Now the debounce only debounces.
    func stopRecording() {
        guard state == .recording else { return }
        enqueueTranscription { [weak self] epoch, previous in
            await self?.runDictationPipeline(epoch: epoch, previous: previous)
        }
    }

    /// The full post-recording pipeline: audio tail → stop capture → save →
    /// transcribe → cleanup → paste. `previous` is the prior pipeline/retry,
    /// awaited before entering the shared ASR backend so it is never used by
    /// two transcriptions concurrently (#104). Shared-UI writes are
    /// epoch-guarded: a pipeline that outlives its session (a newer recording
    /// confirmed, or Esc discarded it) still lands its text in history — and
    /// pastes it, unless deliberately cancelled — but no longer owns the
    /// state/indicator/currentEntryID.
    private func runDictationPipeline(epoch: Int, previous: Task<Void, Never>?) async {
        // Audio tail: keep recording 300ms to capture trailing speech. The
        // sleep is a separate cancellable Task so a new Fn press can cut the
        // tail short (#104) — `startPreBuffer` finalizes the capture on this
        // pipeline's behalf and parks the samples in `cutTailSamples`.
        let tail = Task { () -> Void in try? await Task.sleep(for: .milliseconds(300)) }
        tailTask = tail
        await tail.value
        tailTask = nil

        let samples: [Float]
        if let cut = cutTailSamples {
            // Tail cut by a new press — capture already finalized for us.
            cutTailSamples = nil
            samples = cut
        } else {
            // Re-check state — may have been discarded during the tail
            guard state == .recording, isCurrentSession(epoch) else { return }
            stopMicCapture()
            samples = accumulatedSamples
            accumulatedSamples.removeAll()
        }

        let durationSeconds = Double(samples.count) / 16000.0
        DiagStore.record(.dictationRecorded(
            samples: samples.count,
            durationMs: Int(durationSeconds * 1000)
        ))

        // Zero frames captured = mic failure (e.g. the macOS 27 HAL stall), not a
        // brief utterance. Surface it instead of silently going idle, and don't save
        // an empty history entry. A non-empty but short recording falls through to
        // the quiet "too short" path below, preserving prior behavior.
        guard !samples.isEmpty else {
            // Prefer a concrete bus capture error if one was recorded; otherwise the
            // unified message. Fn is already released here (stop came from the release
            // path), so use the grace hide directly.
            let message = if let lastError { lastError } else { await micUnavailableMessage() }
            DiagStore.record(.dictationZeroFrames)
            // The message can name the resolved input device.
            log.error("zero frames captured — mic failure: \(message, privacy: .private)")
            // The async message lookup may have lost the session to a newer press.
            guard isCurrentSession(epoch) else { return }
            surfaceMicError(message, hide: .grace)
            return
        }

        // Audio was captured, so the recording is proceeding to save/transcribe. If a
        // transient stall set lastError (watchdog or the immediate captureError check)
        // and the mic then recovered and delivered frames, clear it now so the success
        // path doesn't render a stale red error row at `.done`. A cut-tail pipeline
        // can resume after a newer session confirmed, so every shared-UI write from
        // here on is epoch-gated.
        if isCurrentSession(epoch) { lastError = nil }

        guard samples.count > Self.minimumSpeechSamples else {
            log.info("Too short, ignoring")
            if isCurrentSession(epoch) { state = .idle }
            return
        }

        // STEP 1: Save audio to disk FIRST — never lose the recording.
        // Sync the audio retention limit from Settings so add-time pruning
        // honors the user's choice (#52); history stays settings-agnostic.
        history.audioRetentionLimit = settings?.dictationAudioRetentionCount ?? 500
        let audioFilename = history.saveAudio(samples)
        var entry = DictationHistoryEntry(durationSeconds: durationSeconds, audioFilename: audioFilename)
        history.add(entry)
        if isCurrentSession(epoch) { currentEntryID = entry.id }
        log.debug("audio saved: \(audioFilename ?? "FAILED", privacy: .private)")

        // Capture the pre-paste mode now, while it is still this session's —
        // a newer session owns `pendingCleanupMode` once confirmed, and a
        // stale pipeline must not steal the newer session's choice.
        let pending: UpgradeAction?
        if isCurrentSession(epoch) {
            pending = pendingCleanupMode
            pendingCleanupMode = nil
            state = .processing
        } else {
            pending = nil
        }

        // STEP 2: Transcribe — strictly after the previous pipeline finishes:
        // the shared backend must never be entered by two transcriptions (#104).
        await previous?.value
        await transcribeEntry(&entry, samples: samples, epoch: epoch)

        guard entry.status == .transcribed, let rawText = entry.rawText else {
            // Transcription failed (or was cancelled by a discard) — record it;
            // the indicator is touched only while this is the current session.
            history.update(entry)
            guard isCurrentSession(epoch) else { return }
            state = .done
            scheduleAutoHide()
            return
        }

        // A discard that landed after the backend had already produced text:
        // keep the text in history, but never paste a dictation the user
        // threw away.
        if Task.isCancelled {
            history.update(entry)
            return
        }

        // STEP 3: Determine cleanup action (pre-paste mode > defaults) and run
        let cleanupEnabled = settings?.cleanupByDefault ?? false
        let translateEnabled = settings?.translationByDefault ?? false
        let hasApiKey = !(settings?.openaiApiKey.isEmpty ?? true)
        let didCleanup: Bool

        // Mode name and translation meta are written only when the cleanup
        // actually succeeded — a swallowed API failure must not relabel the
        // pasted raw text (DIC-37/48). Pre-paste mode (Fn+V/Fn+T) overrides
        // defaults; translate-by-default implies cleanup.
        if let pending, hasApiKey {
            didCleanup = await runCleanupAction(pending, on: &entry, rawText: rawText, epoch: epoch)
        } else if translateEnabled && hasApiKey {
            didCleanup = await runCleanupAction(.translate, on: &entry, rawText: rawText, epoch: epoch)
        } else if cleanupEnabled && hasApiKey {
            didCleanup = await runCleanupAction(.cleanup, on: &entry, rawText: rawText, epoch: epoch)
        } else {
            didCleanup = false
        }

        // Re-check after the cleanup awaits: a discard that landed during
        // cleanup must not paste either — the text stays in history only.
        if Task.isCancelled {
            history.update(entry)
            return
        }

        // Paste immediately (always paste the best version) — even when a
        // newer recording session is already underway (#104): a completed
        // dictation still lands where the cursor is.
        if let text = entry.cleanedText ?? entry.rawText {
            lastTranscript = text
            TextInserter.paste(text)
            // The pasted text is exactly what the user dictated and is already
            // visible in the app's own history UI — only its length is recorded.
            DiagStore.record(.dictationPasted(characters: text.count, cleaned: didCleanup))
        }

        history.update(entry)

        // STEP 4: the indicator and upgrade panel belong to the newest session.
        guard isCurrentSession(epoch) else { return }
        state = .done

        // Show upgrade options — skip if user explicitly chose a pre-paste mode.
        // A cleanup/translate failure keeps the panel up long enough to read (#50).
        if pending != nil {
            scheduleAutoHide(after: lastError == nil ? .milliseconds(800) : .seconds(4))
        } else {
            showUpgradeOptions(didCleanup: didCleanup)
        }
    }

    // MARK: - Upgrade Panel

    /// Show upgrade panel if API key is available.
    private func showUpgradeOptions(didCleanup: Bool) {
        let hasApiKey = !(settings?.openaiApiKey.isEmpty ?? true)

        guard hasApiKey else {
            // No upgrades possible — just auto-hide after brief checkmark
            scheduleAutoHide()
            return
        }

        isUpgradePanelVisible = true
        cleanupAlreadyApplied = didCleanup
        upgradeCountdown = Self.upgradePanelDuration

        // Start countdown timer for auto-dismiss
        upgradeDismissTask?.cancel()
        upgradeDismissTask = Task { [weak self] in
            let steps = 30
            let stepDuration = Self.upgradePanelDuration / Double(steps)
            for i in 1...steps {
                do {
                    try await Task.sleep(for: .milliseconds(Int(stepDuration * 1000)))
                } catch {
                    return // Cancelled
                }
                guard let self, self.isUpgradePanelVisible else { return }
                self.upgradeCountdown = Self.upgradePanelDuration - (Double(i) * stepDuration)
            }
            guard let self, self.isUpgradePanelVisible else { return }
            self.dismissUpgrades()
        }
    }

    /// Called when user selects an upgrade via hotkey or indicator button
    /// (post-paste C/T): undo the previous paste and re-paste the upgraded text.
    func applyUpgradeByKey(_ action: UpgradeAction) async {
        guard isUpgradePanelVisible else { return }

        upgradeDismissTask?.cancel()
        upgradeDismissTask = nil
        isUpgradePanelVisible = false
        upgradeCountdown = nil

        guard let entryID = currentEntryID,
              var entry = history.entries.first(where: { $0.id == entryID }),
              let rawText = entry.rawText else {
            log.error("upgrade failed: no entry or raw text")
            scheduleAutoHide()
            return
        }

        state = .processing
        // A retry must not carry a stale failure row into a success (#50).
        lastError = nil
        log.debug("applying upgrade: \(String(describing: action), privacy: .public)")

        // Meta is written only on success: a failed upgrade keeps the
        // previous cleaned text and whatever meta truthfully described it
        // (DIC-37/48). `kept: true` selects the upgrade failure wording.
        _ = await runCleanupAction(action, on: &entry, rawText: rawText, kept: true)

        // Undo previous paste, then paste upgraded text
        if let text = entry.cleanedText ?? entry.rawText {
            lastTranscript = text
            TextInserter.undoAndPaste(text)
            log.debug("upgrade pasted (undo+paste): \(text, privacy: .private)")
        }

        history.update(entry)
        state = .done
        scheduleAutoHide(after: lastError == nil ? .milliseconds(800) : .seconds(4))
    }

    /// Dismiss upgrade panel without action.
    func dismissUpgrades() {
        upgradeDismissTask?.cancel()
        upgradeDismissTask = nil
        isUpgradePanelVisible = false
        upgradeCountdown = nil
        scheduleAutoHide()
    }

    /// Hide the indicator after a grace period. The default ~800ms covers the normal
    /// `.done` flash; the mic-error grace path passes ~4s so the message stays readable.
    /// Uses the single `autoHideTask` slot so a subsequent Fn press cancels it via
    /// `startPreBuffer`, and so a flicker that re-arms a release path simply restarts it.
    private func scheduleAutoHide(after delay: Duration = .milliseconds(800)) {
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.state == .done else { return }
            self.state = .idle
        }
    }

    /// Build the unified mic-failure message for the dictation path, resolving the input
    /// device name from AudioBus (enumeration needs no mic permission, so it works even
    /// on the denied path). Async: the name lookup is HAL enumeration and runs on the
    /// shared HAL queue, never on the main thread (#64).
    private func micUnavailableMessage() async -> String {
        let requested = settings?.inputDeviceID ?? 0
        let name = await AudioBus.resolvedInputDeviceName(requested: requested)
        return MicrophonePermission.micUnavailableMessage(deviceName: name)
    }

    func discardRecording() {
        if isPreBuffering {
            cancelPreBuffer()
            return
        }
        guard state == .recording || state == .loadingModel || state == .processing else { return }
        DiagStore.record(.dictationDiscarded(state: state))
        // A deliberate discard cancels this session's own pipeline (#104). An
        // older session's late pipeline (epoch mismatch) is left to finish.
        // The cancelled Task stays referenced either way, so the next
        // transcription still serializes behind its wind-down.
        if let latestTranscription, latestTranscription.epoch == sessionEpoch {
            latestTranscription.task.cancel()
        }
        sessionEpoch += 1
        stopMicCapture()
        accumulatedSamples.removeAll()
        pendingCleanupMode = nil
        state = .idle
    }

    // MARK: - Mic Helpers

    /// Monotonic guard for the async device-resolution hop: every stop bumps it, so a
    /// resolution that lands after its capture was stopped is dropped instead of leaking
    /// a stray AudioBus subscription (#64).
    private var captureEpoch = 0

    private func startMicCapture() {
        guard audioBus != nil else {
            log.error("audioBus not wired")
            return
        }

        // One device selection per recording, via transport allowlist on a fresh
        // enumeration (#39). The result is pinned — no mid-recording switching.
        // Resolution is HAL enumeration and runs on the shared HAL queue, never on
        // the main thread (#64); capture subscribes when the hop returns.
        captureEpoch += 1
        let epoch = captureEpoch
        let requestedDevice = settings?.inputDeviceID ?? 0
        Task { @MainActor [weak self] in
            let selection = await AudioBus.resolveBestInputDevice(requested: requestedDevice)
            guard let self, self.captureEpoch == epoch, let bus = self.audioBus else { return }
            guard self.isPreBuffering || self.state == .recording else { return }
            self.beginMicCapture(on: bus, selection: selection)
        }
    }

    /// Second half of startMicCapture, once the device is resolved. MainActor, and only
    /// reached while the originating pre-buffer/recording is still the active capture.
    private func beginMicCapture(
        on bus: AudioBus,
        selection: (deviceID: AudioDeviceID, redirectedToBuiltIn: Bool)?
    ) {
        bluetoothMicRedirected = selection?.redirectedToBuiltIn ?? false

        let (id, stream) = bus.subscribe(deviceID: selection?.deviceID)
        busConsumerID = id

        // Surface a pre-existing capture failure. This reads prior/stale capture state:
        // `subscribe` starts the new capture asynchronously on AudioBus's halQueue, so
        // this check can't observe the new subscription's outcome — the new capture's
        // immediate stall is the watchdog's job below.
        if let micError = bus.captureError {
            log.error("mic capture error: \(micError, privacy: .private)")
            lastError = micError
        }

        // First-frame watchdog: if the HAL IOProc stalls (macOS 27) and this recording
        // captures no audio within 5s while still active, surface it loudly instead of
        // appearing to record normally. Keyed on this recording's own accumulatedSamples
        // (cleared at startPreBuffer), not AudioBus's process-global hasCapturedFrames —
        // which never resets after the first capture, so it would let the watchdog fire
        // only on the first capture after launch. This makes the guard fire per-recording.
        firstFrameWatchdogTask = Task { @MainActor [weak self, weak bus] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let bus else { return }
            guard self.isPreBuffering || self.state == .recording else { return }
            if self.accumulatedSamples.isEmpty && bus.captureError == nil {
                log.error("no mic audio after 5s")
                self.lastError = await self.micUnavailableMessage()
            }
        }

        audioLevelTask = Task { [weak self, weak bus] in
            var everHadSignal = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let bus else { break }
                self.audioLevel = bus.audioLevel

                if bus.hasSignal { everHadSignal = true }

                // Show "no audio" indicator if we've captured frames but never had signal
                // (truly dead mic), or if the bus reports a capture failure (pinned device
                // died mid-recording and retries are failing/exhausted). Don't show it for
                // normal silence gaps — voice isolation produces digital silence between
                // speech, which is not a mic problem.
                // The device stays pinned — warn honestly, never hop devices (#39).
                let shouldShowNoSignal = (bus.hasCapturedFrames && !everHadSignal)
                    || bus.captureError != nil
                if self.noSignal != shouldShowNoSignal {
                    self.noSignal = shouldShowNoSignal
                }
            }
        }

        recordingTask = Task { [weak self] in
            for await buffer in stream {
                guard let self, !Task.isCancelled else { break }
                if let samples = AudioUtils.extractSamples(buffer, converter: &self.converter) {
                    self.accumulatedSamples.append(contentsOf: samples)
                }
            }
        }
    }

    private func stopMicCapture() {
        captureEpoch += 1
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevel = 0
        if let id = busConsumerID {
            audioBus?.unsubscribe(id)
            busConsumerID = nil
        }
        recordingTask?.cancel()
        recordingTask = nil
        bluetoothMicRedirected = false
        noSignal = false
        onCaptureEnded?(!captureConfirmed)
    }

    /// Toggle pre-paste cleanup mode during recording.
    /// Same action twice → off. Different action → replaces.
    func setPendingMode(_ action: UpgradeAction) {
        guard state == .recording else { return }
        if pendingCleanupMode == action {
            pendingCleanupMode = nil
        } else {
            pendingCleanupMode = action
        }
        log.debug("pending mode: \(self.pendingCleanupMode.map { "\($0)" } ?? "none", privacy: .public)")
    }

    func pasteLastTranscript() {
        // Respect activeVersion of the most recent entry
        if let entry = history.entries.first, let text = entry.displayText {
            TextInserter.paste(text)
        } else if let text = lastTranscript {
            TextInserter.paste(text)
        }
    }

    /// Retry transcription for a failed or audio-only entry. Registered in
    /// the same chain as dictation pipelines (#104), so the shared ASR
    /// backend is never entered by two transcriptions concurrently.
    func retryTranscription(entryID: UUID) async {
        await enqueueTranscription { [weak self] epoch, previous in
            await previous?.value
            await self?.performRetry(entryID: entryID, epoch: epoch)
        }.value
    }

    private func performRetry(entryID: UUID, epoch: Int) async {
        guard var entry = history.entries.first(where: { $0.id == entryID }),
              let filename = entry.audioFilename,
              let samples = history.loadAudio(filename: filename) else {
            log.error("retry failed: no audio for entry")
            return
        }

        entry.status = .audioSaved
        entry.rawText = nil
        entry.cleanedText = nil
        entry.errorMessage = nil
        entry.cleanupMethodName = nil
        entry.translatedToLanguage = nil
        history.update(entry)

        await transcribeEntry(&entry, samples: samples, epoch: epoch)

        if entry.status == .transcribed, let text = entry.rawText {
            await cleanupEntry(&entry, rawText: text, endpoint: .cleanup, epoch: epoch)
        }

        history.update(entry)

        // Indicator state belongs to the newest session (#104).
        guard isCurrentSession(epoch) else { return }
        if entry.status == .transcribed || entry.status == .cleaned {
            state = .done
            scheduleAutoHide()
        } else {
            state = .idle
        }
    }

    // MARK: - Transcription

    /// Eagerly build the private dictation backend so the first dictation pays
    /// no model-load latency. Non-blocking: fire from a detached Task at launch;
    /// launch never waits on it. Idempotent — reuses any in-flight/complete load.
    func prewarm() async {
        _ = try? await ensureOwnBackend()
    }

    /// Return the private dictation backend, building it once. Concurrent callers
    /// (launch prewarm + first transcription) await the same in-flight build
    /// rather than each constructing a backend and double-loading the model.
    private func ensureOwnBackend() async throws -> any TranscriptionBackend {
        if let ownBackend { return ownBackend }
        if let ownBackendTask { return try await ownBackendTask.value }

        log.debug("creating private backend")
        let cache = backendCache
        let task = Task { () throws -> any TranscriptionBackend in
            // Download the model once through the shared cache (its dedup token
            // guarantees a single fetch even when the launch prewarms race); the
            // private build then finds files on disk and only loads its own
            // decoder state, so we never launch two concurrent HF downloads.
            try await cache?.prepare()
            let fresh = ParakeetBackend()
            try await fresh.prepare(onStatus: { _ in }, onProgress: { _ in })
            return fresh
        }
        ownBackendTask = task
        defer { ownBackendTask = nil }
        let backend = try await task.value
        ownBackend = backend
        return backend
    }

    private func transcribeEntry(
        _ entry: inout DictationHistoryEntry, samples: [Float], epoch: Int
    ) async {
        // Ensure the shared cache has downloaded model files (fast no-op if already cached)
        if let cache = backendCache {
            do {
                try await cache.prepare { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.isCurrentSession(epoch) else { return }
                        self.state = .loadingModel
                    }
                }
            } catch is CancellationError {
                // Deliberate discard (#104): quiet stop, entry stays
                // retryable (.audioSaved) — same as the chunk loop, not a
                // scary "Model loading failed: cancelled".
                return
            } catch {
                entry.status = .failed
                entry.errorMessage = "Model loading failed: \(error.localizedDescription)"
                if isCurrentSession(epoch) { lastError = entry.errorMessage }
                history.update(entry)
                return
            }
        } else {
            log.error("backendCache nil — dictation setup may not have run")
        }

        // Use a private backend instance to avoid sharing mutable decoder state
        // with TranscriptionEngine's backend from the shared cache. Deduped so
        // the launch prewarm and this first use don't both build one (see
        // `ensureOwnBackend`); already-warm if prewarm finished at launch.
        let backend: any TranscriptionBackend
        do {
            backend = try await ensureOwnBackend()
        } catch is CancellationError {
            // Deliberate discard (#104): quiet stop, entry stays retryable.
            return
        } catch {
            entry.status = .failed
            entry.errorMessage = "Backend prepare failed: \(error.localizedDescription)"
            if isCurrentSession(epoch) { lastError = entry.errorMessage }
            history.update(entry)
            return
        }

        if isCurrentSession(epoch) { state = .processing }

        // Build chunks, merging short tails into the previous chunk
        var chunks: [[Float]] = []
        for start in stride(from: 0, to: samples.count, by: Self.maxChunkSamples) {
            let end = min(start + Self.maxChunkSamples, samples.count)
            let chunk = Array(samples[start..<end])
            if chunk.count < Self.minimumSpeechSamples && !chunks.isEmpty {
                chunks[chunks.count - 1].append(contentsOf: chunk)
            } else {
                chunks.append(chunk)
            }
        }

        let transcribeStart = Date()
        var segments: [String] = []
        var failedChunks = 0

        // Only a *thrown* attempt is retried — an empty success is silence into
        // the mic, not a failure (#103). `failedChunks` = chunks lost after retries.
        // A CancellationError is a deliberate discard (#104), not a lost chunk:
        // stop quietly, leaving the entry as it was (.audioSaved — retryable).
        // The discard already recorded itself in the diagnostic stream.
        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { return }
            do {
                let segment = try await Self.withRetries(attempts: Self.retryAttempts) {
                    do {
                        return try await backend.transcribe(chunk, previousContext: nil)
                    } catch {
                        log.error("""
                            chunk \(i + 1, privacy: .public)/\(chunks.count, privacy: .public) attempt failed: \
                            \(error.localizedDescription, privacy: .private)
                            """)
                        throw error
                    }
                }
                if !segment.isEmpty {
                    segments.append(segment)
                }
            } catch is CancellationError {
                return
            } catch {
                failedChunks += 1
                log.error("""
                    chunk \(i + 1, privacy: .public)/\(chunks.count, privacy: .public) lost after \
                    \(Self.retryAttempts, privacy: .public) attempts, skipping
                    """)
            }
        }

        let text = segments.joined(separator: " ")
        // The transcript itself is the user's speech — it reaches the history UI and
        // os.Logger's private tier, never a diagnostic event. Only its length does.
        DiagStore.record(.transcribed(
            chunks: chunks.count,
            failedChunks: failedChunks,
            samples: samples.count,
            characters: text.count,
            ms: Int(Date().timeIntervalSince(transcribeStart) * 1000)
        ))
        if text.isEmpty {
            entry.status = .failed
            entry.errorMessage = "Transcription produced empty result"
        } else {
            entry.status = .transcribed
            entry.rawText = text
            log.debug("raw transcription: \(text, privacy: .private)")
        }
    }

    /// Single source of truth mapping an UpgradeAction to its prompt, meta
    /// labels, and failure wording, shared by the paste-time defaults, the
    /// Fn+V/Fn+T chords, and the post-paste C/T upgrade keys. Meta is written
    /// only on success (DIC-37/48); `kept` selects the upgrade-retry failure
    /// wording ("kept pasted text" — the previous paste survives, which may
    /// not be raw).
    private func runCleanupAction(
        _ action: UpgradeAction,
        on entry: inout DictationHistoryEntry,
        rawText: String,
        kept: Bool = false,
        epoch: Int? = nil
    ) async -> Bool {
        let basePrompt = settings?.activeCleanupPrompt ?? CleanupMode.cleanPrompt
        let prompt: String
        let modeName: String
        let translatedTo: String?
        let failureMessage: String
        let endpoint: DiagEvent.Endpoint
        switch action {
        case .cleanup:
            prompt = basePrompt
            modeName = "Cleanup"
            translatedTo = nil
            failureMessage = kept ? Self.cleanupFailedKeptText : Self.cleanupFailedPastedRaw
            endpoint = .cleanup
        case .translate:
            prompt = basePrompt + CleanupMode.translateSuffix()
            modeName = "Translate"
            translatedTo = TranslationLanguage.english.key
            failureMessage = kept ? Self.translateFailedKeptText : Self.translateFailedPastedRaw
            endpoint = .translate
        }

        let succeeded = await cleanupEntry(
            &entry, rawText: rawText, prompt: prompt, failureMessage: failureMessage,
            endpoint: endpoint, epoch: epoch
        )
        DiagStore.record(.dictationUpgrade(endpoint: endpoint, outcome: .init(success: succeeded)))
        guard succeeded else { return false }

        entry.cleanupModeName = modeName
        entry.cleanupMethodName = nil
        entry.translatedToLanguage = translatedTo
        return true
    }

    /// Runs the LLM cleanup and mutates the entry on success. Returns true
    /// only when a cleaned text was actually produced and stored — callers
    /// gate every mode/method/language meta write on this (DIC-37/48).
    ///
    /// `failureMessage`, when provided, is surfaced as `lastError` if the API
    /// call itself fails — the floating indicator renders it as the red
    /// status row instead of a fake success panel (#50). Paths with their own
    /// failure UI (row transforms) pass nil. Internal (not private) so tests
    /// can drive the failure path directly with a stubbed client.
    @discardableResult
    func cleanupEntry(
        _ entry: inout DictationHistoryEntry,
        rawText: String,
        prompt: String? = nil,
        failureMessage: String? = nil,
        endpoint: DiagEvent.Endpoint,
        epoch: Int? = nil
    ) async -> Bool {
        guard let settings, !settings.openaiApiKey.isEmpty else { return false }

        let effectivePrompt: String
        if let prompt, !prompt.isEmpty {
            effectivePrompt = prompt
        } else if settings.cleanupByDefault {
            effectivePrompt = settings.activeCleanupPrompt
        } else {
            return false
        }

        let apiKey = settings.openaiApiKey

        do {
            // One `apiCall` event per attempt, wrapping the HTTP call itself —
            // retries show in the stream as failed→ok sequences (#103).
            let cleaned = try await Self.withRetries(
                attempts: Self.retryAttempts,
                backoff: [.milliseconds(500), .seconds(1)],
                isTransient: Self.isTransientCleanupError
            ) {
                let startedAt = Date()
                do {
                    let cleaned = try await cleanupClient.cleanup(
                        rawText: rawText, prompt: effectivePrompt, apiKey: apiKey
                    )
                    // `CleanupProviding` reports success as a String, not a status code —
                    // nil is the honest answer, and `.ok` already carries the verdict.
                    DiagStore.record(.apiCall(
                        endpoint: endpoint,
                        outcome: .ok,
                        httpStatus: nil,
                        ms: Int(Date().timeIntervalSince(startedAt) * 1000)
                    ))
                    return cleaned
                } catch {
                    DiagStore.record(.apiCall(
                        endpoint: endpoint,
                        outcome: .failed,
                        httpStatus: Self.httpStatus(from: error),
                        ms: Int(Date().timeIntervalSince(startedAt) * 1000)
                    ))
                    throw error
                }
            }
            entry.cleanedText = cleaned
            entry.status = .cleaned
            entry.activeVersion = .cleaned
            return true
        } catch {
            // The cleaned/raw texts are the user's words — they live in the history
            // UI, never in a diagnostic artifact (#82).
            log.error("cleanup failed, using raw text: \(error.localizedDescription, privacy: .private)")
            // A stale session's failure must not paint the newer session's
            // indicator red (#104).
            if let failureMessage, isCurrentSession(epoch) {
                lastError = failureMessage
            }
            return false
        }
    }

    /// HTTP status behind a cleanup failure, when the error carries one.
    private static func httpStatus(from error: any Error) -> Int? {
        if case CleanupClient.CleanupError.apiError(let code) = error { return code }
        return nil
    }

    // MARK: - Retry (#103)

    /// Retry budget shared by the two retried sites (chunk transcription,
    /// LLM cleanup/translate). Field report 3NZRFM57: failures are transient
    /// by demonstration — the same input succeeds on a manual re-run.
    static let retryAttempts = 3

    /// Run `operation` up to `attempts` times, retrying only thrown errors
    /// that `isTransient` accepts, sleeping `backoff[i]` before retry i+1.
    /// Cancellation is never transient, regardless of the predicate — retrying
    /// would resurrect work the caller already abandoned — and it propagates
    /// out of a backoff sleep instead of firing another attempt.
    /// Internal so tests can exercise the helper directly.
    static func withRetries<T>(
        attempts: Int,
        backoff: [Duration] = [],
        isTransient: (any Error) -> Bool = { _ in true },
        _ operation: () async throws -> T
    ) async throws -> T {
        for attempt in 1..<max(attempts, 1) {
            do {
                return try await operation()
            } catch {
                guard !(error is CancellationError), isTransient(error) else { throw error }
                try Task.checkCancellation()
                if backoff.indices.contains(attempt - 1) {
                    try await Task.sleep(for: backoff[attempt - 1])
                }
            }
        }
        return try await operation()
    }

    /// Which `URLError`s are network-shaped enough to retry. An allowlist:
    /// `.cancelled` must not resurrect abandoned work, and `.badURL` or
    /// `.userAuthenticationRequired` won't heal on a second try.
    /// Internal: `SpeechifyClient.isTransient` (#105) shares this table.
    nonisolated static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]

    /// Transient = worth retrying: network-shaped `URLError`s, HTTP 429 and
    /// 5xx. Anything else (bad key, bad request) goes straight to the fallback.
    static func isTransientCleanupError(_ error: any Error) -> Bool {
        if let urlError = error as? URLError {
            return transientURLErrorCodes.contains(urlError.code)
        }
        if case CleanupClient.CleanupError.apiError(let code) = error {
            return code == 429 || (500...599).contains(code)
        }
        return false
    }

    // MARK: - Retroactive Row Transforms (history popovers, DIC-35/36)

    /// Re-clean a history entry with a popover method. Always cleans from the
    /// raw transcription to preserve the original. Returns false on failure
    /// so the row can show visible feedback instead of closing silently (#50).
    @discardableResult
    func cleanupHistoryEntry(entryID: UUID, method: CleanupMethod) async -> Bool {
        let prompt = method.prompt(
            activePresetPrompt: settings?.activeCleanupPrompt ?? CleanupMode.cleanPrompt
        )
        return await applyRowTransform(
            entryID: entryID, prompt: prompt, methodKey: method.key, languageKey: nil
        )
    }

    /// Translate a history entry to a popover language (active preset prompt
    /// + language-parametrized suffix). Always translates from the raw
    /// transcription to preserve the original. Returns false on failure (#50).
    @discardableResult
    func translateHistoryEntry(entryID: UUID, to language: TranslationLanguage) async -> Bool {
        let basePrompt = settings?.activeCleanupPrompt ?? CleanupMode.cleanPrompt
        return await applyRowTransform(
            entryID: entryID,
            prompt: basePrompt + CleanupMode.translateSuffix(to: language),
            methodKey: nil,
            languageKey: language.key
        )
    }

    /// Shared row-transform core: meta keys are persisted only when the
    /// cleanup succeeded — a failed call leaves the previous cleaned text and
    /// its meta untouched (DIC-37/48). Failures do NOT touch `lastError` (the
    /// floating indicator); the history row shows its own transient feedback.
    private func applyRowTransform(
        entryID: UUID,
        prompt: String,
        methodKey: String?,
        languageKey: String?
    ) async -> Bool {
        guard var entry = history.entries.first(where: { $0.id == entryID }),
              let text = entry.rawText else {
            log.error("retroactive cleanup: no raw text for entry")
            return false
        }
        guard !prompt.isEmpty else { return false }

        // A row transform with a target language is a translation, not a cleanup —
        // the default argument this used to take silently mislabelled every
        // retroactive translate as `apiCall(endpoint: .cleanup)`.
        let endpoint: DiagEvent.Endpoint = languageKey == nil ? .cleanup : .translate
        guard await cleanupEntry(&entry, rawText: text, prompt: prompt, endpoint: endpoint) else { return false }
        entry.cleanupMethodName = methodKey
        entry.translatedToLanguage = languageKey
        history.update(entry)
        return true
    }

}
