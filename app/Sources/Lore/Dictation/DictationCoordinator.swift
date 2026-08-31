import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import os

enum UpgradeAction: Sendable {
    case cleanup
    case translate
}

/// How a dictation's words leave: posted by the call, answered by the task
/// (#195, #211). `TextInserter.paste` is the only one the app ever builds.
typealias DictationDelivery = @MainActor ([RichInput.DeliveryStep]) -> Task<Bool, Never>

@Observable
@MainActor
final class DictationCoordinator {
    private(set) var state: DictationState = .idle
    private(set) var audioLevel: Float = 0
    private(set) var lastTranscript: String?
    /// The failure face the bubble is showing, if any (#209) — the sentence
    /// and its one action as one value, never a string a button has to be
    /// guessed from.
    private(set) var lastError: DictationFace?
    /// Pre-paste cleanup mode set during recording via Fn+V/Fn+T.
    private(set) var pendingCleanupMode: UpgradeAction?
    /// Which LLM call is running once transcription itself is done (2026-08-31,
    /// owner's report: "Transcribing" kept standing through the translate call
    /// that follows it). Nil during the ASR call, and for a raw dictation with
    /// no cleanup/translate step at all. Distinct from `pendingCleanupMode`,
    /// which is cleared the moment the pipeline captures it — before
    /// transcription starts — so it cannot name the LLM step that comes after.
    private(set) var llmStage: UpgradeAction?
    /// Fn+K "send to operator" (#122): armed during recording, lands on the
    /// entry as `operatorAddressed` so the dispatcher's dictation door
    /// picks it up. The indicator shows a K badge while armed.
    private(set) var pendingOperatorAddressed = false
    /// True while audio is being buffered before hold is confirmed (pre-buffer phase).
    private(set) var isPreBuffering = false
    /// True when a wireless default input was detected and capture redirected to built-in mic.
    private(set) var bluetoothMicRedirected = false
    /// True when the audio bus reports zero signal (dead mic input).
    private(set) var noSignal = false
    /// Esc has suspended capture in place (#206). Deliberately a flag beside
    /// `state` rather than a sixth `DictationState`: a paused dictation *is* a
    /// recording — one session, one entry, one audio file — and everything that
    /// asks `state == .recording` (the quit guard, the Fn+V/T/K/S chords, the
    /// bubble's own canvas) means to include it. What changes is only what the
    /// capture is doing, and that is what this says.
    private(set) var isPaused = false
    /// `stopRecording` has enqueued this session's pipeline and the pipeline has
    /// not yet taken the capture (#206). `state` stays `.recording` across that
    /// gap — the 300 ms audio tail — so both Esc gestures have to refuse inside
    /// it: a resume would open a microphone the pipeline is about to close, and
    /// a pause would cut the tail short, fire a `dictationPaused` with no pair,
    /// and flash the paused face on its way to Transcribing.
    ///
    /// Its own fact rather than `latestTranscription?.epoch == sessionEpoch`,
    /// which is the same thing only until a history retry is started during a
    /// live recording — that enqueues under this epoch too, and Esc would go
    /// quiet for as long as the retry ran.
    private var endingInFlight = false
    /// What the user copied or screenshotted while this dictation was being
    /// spoken (#192), oldest first — the indicator's count and list read this,
    /// and the paste carries every item still switched on. Cleared when the
    /// next recording is confirmed and when one is discarded; the pipeline
    /// takes a copy with it, and what stays is what the transcribing face
    /// keeps counting until the next dictation replaces it (#209).
    private(set) var items: [DictationItem] = []

    private let log = Logger(subsystem: "com.lore.app", category: "DictationCoordinator")
    private var busConsumerID: UUID?
    private var recordingTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var firstFrameWatchdogTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?
    /// True when a mic error is parked in `.done` while Fn may still be held — it must
    /// stay visible (no auto-hide) until the genuine Fn release starts the grace hide.
    private var micErrorSticky = false
    /// A sticky mic error whose message is still resolving on the HAL queue (#64).
    /// If the Fn release arrives before it lands, `pendingStickyRelease` makes it land
    /// with the grace hide instead of sticking with no dismissal path.
    private var stickyErrorInFlight = false
    private var pendingStickyRelease = false
    private var accumulatedSamples: [Float] = []
    /// The recording being written to disk while the user speaks (#182), from
    /// the confirmed hold until whichever path ends the capture. `stopMicCapture`
    /// hands it to that path, which either adopts it into history or abandons
    /// it — nothing else may hold it, and no path may drop it silently.
    private var liveRecording: LiveDictationRecording?
    private var converter: AVAudioConverter?
    private let cleanupClient: any CleanupProviding
    /// The clipboard door (#192): open between the confirmed hold and the end
    /// of the capture, never outside it.
    private let clipboard: ClipboardWatcher
    /// Where this dictation's t=0 sits on the wall clock: the instant the
    /// running capture leg began, moved back by however much audio the dictation
    /// already held when it did. That t=0 is the pre-buffer's first sample — the
    /// same t=0 the model's token timings count from — so `audioOffsetNow` is one
    /// subtraction.
    ///
    /// A leg, not the recording: the first starts at the confirmed hold and
    /// carries the pre-buffer, and a resume after Esc starts another carrying
    /// everything spoken before the pause (#206). Re-placing t=0 is the whole of
    /// what a resume has to do about time — the pause is in no leg, so it is in
    /// neither the audio nor the offsets stamped on what was copied. Nil while
    /// no leg is running.
    private var legEpochStart: Date?

    /// How long a failure face stays up before the shape leaves — long enough
    /// to read one sentence and reach for its button.
    private static let faceReadingTime: Duration = .seconds(4)

    private static let minimumSpeechSamples = 8000
    private static let maxChunkSamples = 480_000
    private static let sampleRate = 16000.0

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

    /// Dictation's own prepared instance — a second cache, not a second dedup:
    /// the launch prewarm and a real first dictation join one build here, on
    /// the same terms as `backendCache`. Why dictation holds an instance of its
    /// own at all, and for how long: `docs/decisions.md` 2026-08-15 (#169), #185.
    private let ownCache: SharedBackendCache

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
    /// finalizes the capture synchronously, and parks the samples — and the
    /// recording they were written to — in `cutTail` for the pipeline to pick up.
    private var tailTask: Task<Void, Never>?
    private var cutTail: (samples: [Float], recording: LiveDictationRecording?, items: [DictationItem])?

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
    /// Fired the instant a live recording ends by any path — Stop recording
    /// (`finishWithoutPasting`), a normal Fn-release/lock-click `stopRecording`,
    /// or a discard — regardless of what the pipeline eventually does with it
    /// (paste, a failure face, nothing). This is the one seam both `finish` and
    /// `discardRecording` call through (#225): the Space lock is a fact about a
    /// gesture that is over the moment any of these run, even though the
    /// pipeline's own 300ms tail and save continue in the background.
    /// `HotkeyManager` is the one subscriber, wired in `install`; its own
    /// Fn-release and lock-click endings already clear the lock synchronously
    /// before this ever fires, so their subscriber call is a no-op for them —
    /// this exists for every path that does not already know about the lock.
    var onRecordingEnding: (() -> Void)?

    /// How this dictation's words leave (#195, #211).
    ///
    /// Called for its effect and answered later: the call *posts* the paste, and
    /// the task it hands back reports only whether the keystrokes could be
    /// created (`TextInserter.paste`). Nothing on the way out waits for that.
    @ObservationIgnored
    private let deliver: DictationDelivery

    /// `history` is injectable so tests can back it with an ephemeral
    /// UserDefaults suite instead of the user's real dictation history;
    /// `cleanupClient` so tests can force LLM failures without the network;
    /// `backend` so tests can drive the chunk loop without the local model;
    /// `deliver` so tests can reach the paste at all — the real one writes the
    /// pasteboard and presses Cmd+V into whatever the developer has in front of
    /// them — and because the order the paste moment turns on, the words posted
    /// before the shape starts leaving, can only be read from inside it (#211).
    init(
        history: DictationHistory = DictationHistory(),
        cleanupClient: any CleanupProviding = CleanupClient(),
        backend: (any TranscriptionBackend)? = nil,
        clipboard: ClipboardWatcher = ClipboardWatcher(),
        deliver: @escaping DictationDelivery = { steps in
            Task { @MainActor in await TextInserter.paste(steps) }
        }
    ) {
        self.history = history
        self.cleanupClient = cleanupClient
        self.clipboard = clipboard
        self.deliver = deliver
        self.ownCache = backend.map { stub in SharedBackendCache(makeBackend: { stub }) }
            ?? SharedBackendCache()
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
            // `cutTail`.
            guard latestTranscription?.epoch == sessionEpoch, let tailTask else { return }
            tailTask.cancel()
            self.tailTask = nil
            // The items go with the recording they were collected during, not
            // with the one this press is starting (#192).
            cutTail = (samples: accumulatedSamples, recording: stopMicCapture(), items: items)
            items.removeAll()
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
                self.surfaceFace(.micUnavailable(await self.micUnavailableMessage()), hide: .grace)
            }
        @unknown default:
            failPreBuffer(MicrophonePermission.unknownMessage)
        }
    }

    /// How a surfaced failure face should hide.
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
        surfaceFace(.micUnavailable(message), hide: .sticky)
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
            self.surfaceFace(.micUnavailable(message), hide: hide)
        }
    }

    /// Show a failure face in the floating indicator. The indicator only renders
    /// while non-idle, so we park in `.done`. A sticky error stays until the Fn
    /// release (`dismissMicErrorAfterRelease`); a grace error hides after a readable ~4s.
    private func surfaceFace(_ face: DictationFace, hide: MicErrorHide) {
        lastError = face
        state = .done
        switch hide {
        case .sticky:
            autoHideTask?.cancel()
            autoHideTask = nil
            micErrorSticky = true
        case .grace:
            micErrorSticky = false
            scheduleAutoHide()
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
        scheduleAutoHide()
    }

    /// Confirm that the hold gesture was detected — transition to visible recording.
    func confirmRecording() {
        guard isPreBuffering else { return }
        isPreBuffering = false
        // The confirmed recording takes ownership of the shared UI state
        // (#104): a pipeline still finishing an earlier dictation goes stale
        // for state/indicator writes (history update and paste are not
        // gated). Only now, at confirm — an unconfirmed pre-buffer (a tap)
        // must not strip the finishing session's error row, entry id, or
        // pending auto-hide.
        sessionEpoch += 1
        autoHideTask?.cancel()
        autoHideTask = nil
        currentEntryID = nil
        // An earlier dictation's ending is not this one's (#206). Every route
        // out of one already crosses `stopMicCapture`, which clears it; this is
        // here because the cost of being wrong about that is a latch that takes
        // Esc away for the rest of the session, and because "the new recording
        // owns the shared state" is exactly what this block is.
        endingInFlight = false
        pendingCleanupMode = nil
        pendingOperatorAddressed = false
        llmStage = nil
        lastError = nil
        captureConfirmed = true
        state = .recording
        // Only past the tap threshold does the audio start reaching disk (#182):
        // a pre-buffer is a gesture that may still turn out to be nothing, and
        // nothing must leave a file. What it already holds goes in first.
        liveRecording = history.beginRecording()
        liveRecording?.append(accumulatedSamples)
        // The audio's t=0 is the pre-buffer's first sample, so "now" in this
        // dictation is however much audio the pre-buffer already holds, plus
        // whatever elapses from here (#192). Measured, not assumed at 150 ms:
        // a hold that beat the threshold by a few ms carries less.
        beginCaptureLeg()
        items.removeAll()
        openClipboardDoor()
        log.debug("recording confirmed (pre-buffer kept)")
    }

    /// Place this dictation's t=0 for the leg about to run (#206). Whatever is
    /// already in `accumulatedSamples` is behind it, so the first leg carries the
    /// pre-buffer and a resume carries everything spoken before the pause —
    /// measured, never assumed, so no wall clock that ran while nothing was
    /// captured can get into the numbers.
    private func beginCaptureLeg() {
        legEpochStart = Date().addingTimeInterval(-capturedSeconds)
    }

    /// How long this dictation's audio is. Sample-accurate by construction — it
    /// counts what was captured — so it stops of its own accord when Esc pauses
    /// the capture and picks up exactly where it stopped.
    private var capturedSeconds: Double {
        Double(accumulatedSamples.count) / Self.sampleRate
    }

    /// The same figure in whole seconds, which is what the floating bubble's
    /// timer shows (#206). The bubble reads this rather than keeping a clock of
    /// its own: a poller that started and stopped one by noticing `isPaused`
    /// flip was deriving both pause edges from when it happened to look, and
    /// paid up to a poll interval of drift for each of them.
    var elapsedCaptureSeconds: Int { Int(capturedSeconds) }

    /// The clipboard door (#192), opened at the confirmed hold and at every
    /// resume. `start` re-reads the pasteboard's change count, so what was
    /// copied while the dictation stood paused is not something that happened
    /// during it — the same rule the beginning of a recording already applies.
    private func openClipboardDoor() {
        clipboard.start(
            offset: { [weak self] in self?.audioOffsetNow() ?? 0 },
            onItem: { [weak self] item in self?.items.append(item) }
        )
    }

    // MARK: - Pause (#206)

    /// Esc: suspend capture in place. One session, one entry, one audio file —
    /// the recording's file stays open behind every buffer already queued, and a
    /// resume appends to it, so the audio is contiguous samples with no gap
    /// spliced into the middle of it (#182 writes a raw stream; a pause is
    /// simply the absence of the next append, and needs no silence pad the way a
    /// meeting's two tracks do).
    ///
    /// What goes down is the capture and the doors that only make sense beside
    /// it: the bus subscription, the level meter, the first-frame watchdog and
    /// the clipboard. Nothing collects while paused, and no watchdog can accuse
    /// a microphone of failing to deliver frames nobody asked it for.
    /// Never against a dictation that is already ending — see `endingInFlight`.
    func pauseRecording() {
        guard state == .recording, !isPaused, !endingInFlight else { return }
        isPaused = true
        tearDownCapture()
        DiagStore.record(.dictationPaused)
        log.debug("recording paused (Esc)")
    }

    /// The second Esc: the same recording, carrying on. Capture comes back up on the
    /// device the pinned selection resolves to, the clipboard door reopens, and
    /// the offsets pick up from the audio already held rather than from a wall
    /// clock that ran through the pause.
    ///
    /// Never against a dictation that is already ending — see `endingInFlight`.
    func resumeRecording() {
        guard state == .recording, isPaused, !endingInFlight else { return }
        isPaused = false
        beginCaptureLeg()
        startMicCapture()
        openClipboardDoor()
        DiagStore.record(.dictationResumed)
        log.debug("recording resumed")
    }

    /// How far into this dictation's audio "now" is. Zero before a hold is
    /// confirmed and while one is paused — nothing collects then.
    private func audioOffsetNow() -> Double {
        guard let legEpochStart else { return 0 }
        return Date().timeIntervalSince(legEpochStart)
    }

    /// Switch one item between in the prompt and left out (#192) — the row in
    /// the indicator's list is the switch, and the count follows.
    func toggleItem(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].included.toggle()
        DiagStore.record(.dictationItemSwitched(
            kind: items[index].kind, included: items[index].included
        ))
    }

    /// Cancel pre-buffer (user tapped instead of holding).
    func cancelPreBuffer() {
        guard isPreBuffering else { return }
        isPreBuffering = false
        stopMicCapture()?.abandon()
        accumulatedSamples.removeAll()
        log.debug("pre-buffer discarded (tap)")
    }

    /// Stop the current recording. The save→transcribe→paste pipeline runs in
    /// a coordinator-owned Task (#104): the hotkey release-debounce Task that
    /// calls this is cancelled first thing by the next Fn press, and when the
    /// pipeline ran inline there, that press killed the in-flight
    /// transcription and lost the dictation. Now the debounce only debounces.
    func stopRecording() {
        finish(pasting: true)
    }

    /// `Stop recording` on the paused bubble (#219): the same ending, with the
    /// words kept and nothing inserted — "when you press stop recording, then
    /// this recording just stays, and doesn't insert anything, it just kind of
    /// disappears."
    ///
    /// Everything else is a finish like any other: the same pipeline, the same
    /// entry, its audio, its words and its items in history. What it does not do
    /// is deliver — no paste, no paste events, no mark — and the shape leaves as
    /// soon as the entry is saved rather than standing through the
    /// transcription, because the button the user just pressed said so. A
    /// transcription that fails after that is history's own retry, not a face
    /// for a bubble that has gone.
    func finishWithoutPasting() {
        finish(pasting: false)
    }

    /// Which of the two, in the one place the decision is taken: the pipeline is
    /// handed it at the moment it is enqueued, so a newer dictation starting
    /// during the 300 ms tail cannot change what this one does.
    private func finish(pasting: Bool) {
        guard state == .recording else { return }
        onRecordingEnding?()
        endingInFlight = true
        enqueueTranscription { [weak self] epoch, previous in
            await self?.runDictationPipeline(epoch: epoch, previous: previous, pasting: pasting)
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
    private func runDictationPipeline(
        epoch: Int, previous: Task<Void, Never>?, pasting: Bool
    ) async {
        // Audio tail: keep recording 300ms to capture trailing speech. The
        // sleep is a separate cancellable Task so a new Fn press can cut the
        // tail short (#104) — `startPreBuffer` finalizes the capture on this
        // pipeline's behalf and parks the samples in `cutTailSamples`.
        let tail = Task { () -> Void in try? await Task.sleep(for: .milliseconds(300)) }
        tailTask = tail
        await tail.value
        tailTask = nil

        let samples: [Float]
        // The recording this pipeline now owns: adopted into history below, or
        // abandoned on the way out (#182).
        let recording: LiveDictationRecording?
        // What was copied while it was being spoken (#192) — this pipeline's,
        // not the next recording's.
        let gathered: [DictationItem]
        if let cut = cutTail {
            // Tail cut by a new press — capture already finalized for us.
            cutTail = nil
            samples = cut.samples
            recording = cut.recording
            gathered = cut.items
        } else {
            // Re-check state — may have been discarded during the tail
            // (which abandoned the recording along with it).
            guard state == .recording, isCurrentSession(epoch) else { return }
            recording = stopMicCapture()
            samples = accumulatedSamples
            accumulatedSamples.removeAll()
            gathered = items
            // Not cleared here: the transcribing face keeps showing the clip
            // and its count, so the person can see their items are still
            // riding along (#209, T1). They go when the next recording is
            // confirmed, or when one is discarded — which is what this
            // property's own contract already said.
        }
        // The paperclip's state at release decides (#208), read live here and
        // nowhere downstream: off means nothing rides along, and the items
        // stay on the entry marked left out so history still shows them.
        let collected = RichInput.atRelease(
            gathered, collecting: RichInputSettings.isOn(.collect)
        )

        let durationSeconds = Double(samples.count) / Self.sampleRate
        DiagStore.record(.dictationRecorded(
            samples: samples.count,
            durationMs: Int(durationSeconds * 1000)
        ))

        // Zero frames captured = mic failure (e.g. the macOS 27 HAL stall), not a
        // brief utterance. Surface it instead of silently going idle, and don't save
        // an empty history entry. A non-empty but short recording falls through to
        // the quiet "too short" path below, preserving prior behavior.
        guard !samples.isEmpty else {
            recording?.abandon()
            // Prefer a concrete bus capture error if one was recorded; otherwise the
            // unified message. Fn is already released here (stop came from the release
            // path), so use the grace hide directly.
            let face = if let lastError { lastError } else {
                DictationFace.micUnavailable(await micUnavailableMessage())
            }
            DiagStore.record(.dictationZeroFrames)
            // The sentence can name the resolved input device.
            log.error("zero frames captured — mic failure: \(face.sentence, privacy: .private)")
            // The async message lookup may have lost the session to a newer press.
            guard isCurrentSession(epoch) else { return }
            surfaceFace(face, hide: .grace)
            return
        }

        // Audio was captured, so the recording is proceeding to save/transcribe. If a
        // transient stall set lastError (watchdog or the immediate captureError check)
        // and the mic then recovered and delivered frames, clear it now so the success
        // path doesn't render a stale red error row at `.done`. A cut-tail pipeline
        // can resume after a newer session confirmed, so every shared-UI write from
        // here on is epoch-gated.
        if isCurrentSession(epoch) { lastError = nil }

        // A hold too short to be speech is nothing — unless something rode
        // along with it (#229). Screenshots and copies are content in their own
        // right: the dictation carries on into the pipeline, transcribes to
        // nothing, and composes to the items alone. Abandoning here dropped
        // them before they were ever saved.
        guard samples.count > Self.minimumSpeechSamples || collected.contains(where: \.included)
        else {
            recording?.abandon()
            log.info("Too short, ignoring")
            if isCurrentSession(epoch) { state = .idle }
            return
        }

        // STEP 1: the audio is already at its final path — capture wrote it
        // there as the user spoke (#182), and the entry beside it. Only a
        // recording that never reached disk still needs the blob written here.
        // Sync the audio retention limit from Settings so add-time pruning
        // honors the user's choice (#52); history stays settings-agnostic.
        history.audioRetentionLimit = settings?.dictationAudioRetentionCount ?? 500
        var entry = recording?.completed(durationSeconds: durationSeconds)
            ?? DictationHistoryEntry(
                durationSeconds: durationSeconds, audioFilename: history.saveAudio(samples)
            )
        // Fn+K (#122): the flag belongs to this session — a stale pipeline
        // must not steal a newer session's arming (same rule as `pending`
        // below). Set before `add` so the entry's FIRST write carries it;
        // the indicator's K badge survives the consumption because
        // `operatorAddressedDisplayed` follows the entry from here on.
        if isCurrentSession(epoch) {
            if pendingOperatorAddressed { entry.operatorAddressed = true }
            pendingOperatorAddressed = false
        }
        // Rich input (#192): the clipboard images become files beside the entry
        // they belong to, so the prompt can name a path a CLI agent can open.
        // On the entry before `add`, so its first write already carries them —
        // and so a retry re-composes the same text from the same items.
        entry.items = Self.materialize(collected, entryID: entry.id)
        history.add(entry)
        if isCurrentSession(epoch) { currentEntryID = entry.id }
        log.debug("audio saved: \(entry.audioFilename ?? "FAILED", privacy: .private)")

        // Capture the pre-paste mode now, while it is still this session's —
        // a newer session owns `pendingCleanupMode` once confirmed, and a
        // stale pipeline must not steal the newer session's choice.
        let pending: UpgradeAction?
        if isCurrentSession(epoch) {
            pending = pendingCleanupMode
            pendingCleanupMode = nil
            // The entry is in history with its audio, so a `Stop recording` has
            // everything it promised and the shape leaves here (#219). The rest
            // of the pipeline runs on without it.
            state = pasting ? .processing : .idle
        } else {
            pending = nil
        }

        // STEP 2: Transcribe — strictly after the previous pipeline finishes:
        // the shared backend must never be entered by two transcriptions (#104).
        await previous?.value
        await transcribeEntry(&entry, samples: samples, epoch: epoch, showsProgress: pasting)

        guard entry.status == .transcribed, let rawText = entry.rawText else {
            // Transcription failed (or was cancelled by a discard) — record it;
            // the indicator is touched only while this is the current session,
            // and a `Stop recording` has already taken the shape off the screen
            // (#219): what failed here is history's own retry.
            history.update(entry)
            guard pasting, isCurrentSession(epoch) else { return }
            // The app knew this had happened and said "Done" anyway (#209, F2).
            // A model download that failed already put its own face up; anything
            // else here is a dictation that came back with nothing in it.
            if lastError == nil { lastError = .nothingCameThrough }
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

        // Pre-paste mode (Fn+V/Fn+T) overrides defaults; translate-by-default
        // implies cleanup. Resolved once — the mode itself is one decision,
        // not three copies of the same `hasApiKey` gate that can (and did)
        // drift apart from `llmStage`'s own three copies below.
        let action: UpgradeAction? = pending
            ?? (translateEnabled ? .translate : (cleanupEnabled ? .cleanup : nil))
        let didCleanup: Bool
        // Mode name and translation meta are written only when the cleanup
        // actually succeeded — a swallowed API failure must not relabel the
        // pasted raw text (DIC-37/48).
        // A dictation that is only its items has nothing to send (#229): the
        // model would be asked for nothing, `cleanupSegments` would make no
        // call at all, and the same text would come back stamped cleaned —
        // a badge, a toggle and an `.ok` upgrade event over an untouched
        // string. Asked here, so the stage never names the call either.
        let hasWords = RichInput.hasSpokenWords(in: rawText, items: entry.items ?? [])
        if let action, hasApiKey, hasWords {
            // `llmStage` names this call while it runs, so the bubble's working
            // sentence can say "Translating…"/"Cleaning up…" instead of always
            // reading "Transcribing" (owner, 2026-08-31) — set right before the
            // await, gated the same way `lastError` already is: a stale
            // pipeline's own stage must not paint a newer session's bubble.
            // Only while `pasting`: a `finishWithoutPasting` ending has already
            // taken the bubble off screen (#219), and a stage for a face nobody
            // sees is a reader trap.
            if pasting, isCurrentSession(epoch) { llmStage = action }
            didCleanup = await runCleanupAction(action, on: &entry, rawText: rawText, epoch: epoch)
        } else {
            didCleanup = false
        }
        if isCurrentSession(epoch) { llmStage = nil }

        // Re-check after the cleanup awaits: a discard that landed during
        // cleanup must not paste either — the text stays in history only.
        if Task.isCancelled {
            history.update(entry)
            return
        }

        // Paste immediately (always paste the best version) — even when a
        // newer recording session is already underway (#104): a completed
        // dictation still lands where the cursor is. Unless the user asked for
        // the words to be kept and not inserted (#219), which is the whole of
        // what `Stop recording` does differently: no delivery, and so no paste
        // events and no mark either.
        var delivery: Task<Bool, Never>?
        if let text = entry.cleanedText ?? entry.rawText {
            lastTranscript = text
            if pasting {
                // Where the words are about to land decides the form the items take
                // (#195): a terminal's agent opens a path, a web composer has to be
                // handed the file. Read now — the user may have changed windows
                // while this was being transcribed.
                let target = PasteTarget.frontmost
                let steps = RichInput.delivery(text: text, items: entry.items ?? [], target: target)
                // Started here, answered below (#209, F5). A web composer is handed
                // its steps 250–600 ms apart, and nothing in this function may wait
                // for that: the shape leaves at STEP 4 and this outlives it.
                delivery = deliver(steps)
                // The pasted text is exactly what the user dictated and is already
                // visible in the app's own history UI — only its length is recorded.
                DiagStore.record(.dictationPasted(characters: text.count, cleaned: didCleanup))
                if let items = entry.items, !items.isEmpty {
                    DiagStore.record(.dictationItemsPasted(
                        items: items.count,
                        included: items.filter(\.included).count,
                        target: target
                    ))
                    // The folder that just grew is brought back under its ceiling
                    // (#196) — after the paste, off this actor, oldest first. What
                    // was named a moment ago is the newest thing in it.
                    if items.contains(where: { $0.kind == .image }) {
                        let limit = RichInputSettings.keepMegabytes
                        Task.detached(priority: .utility) {
                            RichInputStore.pruneToCap(limitMegabytes: limit)
                        }
                    }
                }
            }
        }

        history.update(entry)

        // STEP 4: the indicator belongs to the newest session — and to a
        // dictation that was going to be pasted, since a `Stop recording` took
        // the shape off the screen when the entry was saved (#219).
        guard pasting, isCurrentSession(epoch) else { return }
        // Whether the keystrokes could be created is the one thing this side
        // can observe — `CGEvent.post` returns no receipt — and the answer
        // arrives after the shape has already gone, which is the honest order:
        // as far as this side could tell the words were away, and then they
        // were not. Watched from here rather than after the writes below, so a
        // cleanup failure's own face is replaced by this one — "pasted raw
        // text" is not true of a paste that never happened.
        if let delivery {
            Task { @MainActor [weak self] in
                let posted = await delivery.value
                guard !posted, let self, self.isCurrentSession(epoch) else { return }
                self.surfaceFace(.pasteFailed, hide: .grace)
            }
        }
        guard lastError == nil else {
            // F6: the raw text landed, and the row says why it is unedited.
            state = .done
            scheduleAutoHide()
            return
        }
        // The paste moment (#211, #218). The words went at `deliver` above —
        // before this write, with nothing between the two that waits — and the
        // shape says so on its way out: the spinner's slot becomes a green
        // checkmark, which bursts where it stands as the bubble closes with it.
        // What V-A refused (#209) is refused still: nothing is claimed about the
        // words *arriving* — `TextInserter` can confirm only that the Cmd+V was
        // created — and nothing is parked for anyone to dismiss. This is the
        // shape leaving, drawn.
        state = .done
        scheduleAutoHide(after: PasteMark.hold)
    }

    /// Clipboard images become PNGs under lore's own Application Support — the
    /// one thing this feature stores (#192, D4). An image whose file could not
    /// be written is dropped rather than carried: a prompt must never name a
    /// picture that is not there. Nil when nothing survived, so a dictation
    /// with nothing attached keeps its byte-identical JSON.
    private static func materialize(_ items: [DictationItem], entryID: UUID) -> [DictationItem]? {
        var kept: [DictationItem] = []
        for (index, item) in items.enumerated() {
            var item = item
            if item.kind == .image {
                guard let data = item.imageData,
                      let path = RichInputStore.writePNG(data, entryID: entryID, index: index)
                else { continue }
                item.path = path
            }
            // The bytes are a file now; a second copy inside the entry's JSON
            // would be the same picture twice.
            item.imageData = nil
            kept.append(item)
        }
        return kept.isEmpty ? nil : kept
    }

    /// Hide the indicator once its face has had time to be read. Uses the single
    /// `autoHideTask` slot so a subsequent Fn press cancels it via
    /// `startPreBuffer`, and so a flicker that re-arms a release path simply
    /// restarts it.
    ///
    /// Two delays: a failure face's four seconds — long enough to read one
    /// sentence and reach for its button — and `PasteMark.hold`, which is not
    /// reading time at all but the length of the mark's own burst (#218).
    /// Both end the same way, so they are one task and one slot; neither is the
    /// ~800 ms "Done" flash this used to default to (#209).
    private func scheduleAutoHide(after delay: Duration = DictationCoordinator.faceReadingTime) {
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
        onRecordingEnding?()
        DiagStore.record(.dictationDiscarded(state: state))
        // A deliberate discard cancels this session's own pipeline (#104). An
        // older session's late pipeline (epoch mismatch) is left to finish.
        // The cancelled Task stays referenced either way, so the next
        // transcription still serializes behind its wind-down.
        if let latestTranscription, latestTranscription.epoch == sessionEpoch {
            latestTranscription.task.cancel()
        }
        sessionEpoch += 1
        // Nothing behind, on disk as in memory (#182) — unless the pipeline
        // already adopted the recording, and then there is nothing to hand over.
        stopMicCapture()?.abandon()
        accumulatedSamples.removeAll()
        // A discarded dictation takes its items with it — there is no inbox of
        // things that were copied during a recording that never happened.
        items.removeAll()
        pendingCleanupMode = nil
        pendingOperatorAddressed = false
        llmStage = nil
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
            guard self.isPreBuffering || (self.state == .recording && !self.isPaused) else { return }
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
        //
        // The driver's own string never reaches the row (#209, F1): both paths
        // read the one plain sentence, which the watchdog below already used.
        // Resolving the device name hops to the HAL queue (#64), so the capture
        // epoch is what keeps a message from landing on a recording that has
        // already been stopped or discarded.
        if let micError = bus.captureError {
            log.error("mic capture error: \(micError, privacy: .private)")
            let epoch = captureEpoch
            Task { @MainActor [weak self] in
                guard let self else { return }
                let message = await self.micUnavailableMessage()
                guard self.captureEpoch == epoch else { return }
                self.lastError = .micUnavailable(message)
            }
        }

        // First-frame watchdog: if the HAL IOProc stalls (macOS 27) and this leg
        // captures no audio within 5s while still active, surface it loudly instead of
        // appearing to record normally. Keyed on this leg's own share of
        // accumulatedSamples, not AudioBus's process-global hasCapturedFrames —
        // which never resets after the first capture, so it would let the watchdog fire
        // only on the first capture after launch. The leg's own count rather than
        // "empty" so a leg brought back up by a resume is watched too (#206): after a
        // resume the dictation already holds audio, and an emptiness test could never
        // be true again. The pause itself is not watched at all — the task is cancelled
        // with the capture, so no microphone is accused of withholding frames nobody
        // asked it for.
        let heldAtLegStart = accumulatedSamples.count
        firstFrameWatchdogTask = Task { @MainActor [weak self, weak bus] in
            try? await Task.sleep(for: .seconds(5))
            // A cancelled sleep returns rather than throwing past `try?`, so
            // without this the body runs the instant the capture is torn down —
            // and a pause inside the first five seconds would accuse a microphone
            // of delivering nothing when nothing had been asked of it
            // (`no-false-positives.md`). The stop path was one main-actor yield
            // away from the same accusation.
            guard !Task.isCancelled else { return }
            guard let self, let bus else { return }
            guard self.isPreBuffering || self.state == .recording else { return }
            if self.accumulatedSamples.count == heldAtLegStart && bus.captureError == nil {
                log.error("no mic audio after 5s")
                self.lastError = .micUnavailable(await self.micUnavailableMessage())
            }
        }

        audioLevelTask = Task { [weak self, weak bus] in
            var everHadSignal = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                // As above: the cancelled sleep falls through, and one more pass
                // here would put a level and a no-signal verdict back on a
                // capture that has just been torn down.
                guard !Task.isCancelled, let self, let bus else { break }
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
                    self.appendCapturedSamples(samples)
                }
            }
        }
    }

    /// One capture buffer, two destinations: memory for the transcription about
    /// to run, and the recording's own file so the words survive a kill before
    /// the key is released (#182). This runs on the main actor while the user is
    /// speaking, so the write itself belongs to the recording's serial queue.
    /// Internal so tests drive the loop without opening a microphone.
    func appendCapturedSamples(_ samples: [Float]) {
        accumulatedSamples.append(contentsOf: samples)
        liveRecording?.append(samples)
    }

    /// End the capture and hand back the recording it was writing (#182). Not
    /// discardable: every caller says what becomes of it — adopted into
    /// history, parked for the pipeline that owns it, or abandoned — so no path
    /// can leave a file behind. Nil when the gesture never became a recording.
    private func stopMicCapture() -> LiveDictationRecording? {
        tearDownCapture()
        // A dictation that ends while paused ends as a dictation: the file is
        // closed and handed on below, exactly as a release would (#206). The
        // ending it was refusing Esc for is over at the same instant.
        isPaused = false
        endingInFlight = false
        // After `tearDownCapture` cancelled the capture loop: it appends on this
        // actor, so no buffer reaches the file past this point, and `finish`
        // closes it behind every buffer already queued.
        let recording = liveRecording
        liveRecording = nil
        recording?.finish()
        onCaptureEnded?(!captureConfirmed)
        return recording
    }

    /// Everything the capture leg owns, dropped: the bus subscription, the
    /// buffer loop, the level meter, the first-frame watchdog and the clipboard
    /// door (#192 — open only while a leg is running). Shared by the stop that
    /// ends a dictation and the Esc that pauses one (#206); what tells them
    /// apart is what becomes of the recording's file, which is
    /// `stopMicCapture`'s alone. Idempotent, so a stop after a pause crosses it
    /// harmlessly a second time.
    private func tearDownCapture() {
        captureEpoch += 1
        clipboard.stop()
        // The leg's clock goes with the leg: nothing collects once the door is
        // shut, and a resume places a new t=0 rather than remembering this one.
        legEpochStart = nil
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

    /// Toggle the operator-addressed flag during recording (Fn+K, #122).
    /// Same toggle idiom as `setPendingMode`: pressed twice → off.
    ///
    /// The one chokepoint the master switch (#223) sits on: the key paths and
    /// the bubble's own click both arrive here, so with the switch off no
    /// dictation can be armed by any route. A coordinator with no settings
    /// cannot read the switch, and a switch that is off on every fresh install
    /// must read as off when it cannot be read at all.
    func toggleOperatorAddressed() {
        guard state == .recording, settings?.operatorSendEnabled == true else { return }
        pendingOperatorAddressed.toggle()
        log.debug("operator addressed: \(self.pendingOperatorAddressed, privacy: .public)")
    }

    /// The K letter's state in the rail (#122): armed while recording
    /// (`pendingOperatorAddressed`), then — after the pipeline consumes the
    /// arming into the entry's first write — the entry's own flag. Keeps the
    /// letter from going dark at entry write, mid-dictation.
    var operatorAddressedDisplayed: Bool {
        if pendingOperatorAddressed { return true }
        guard let entryID = currentEntryID else { return false }
        return history.entries.first(where: { $0.id == entryID })?.operatorAddressed == true
    }

    func pasteLastTranscript() {
        // Respect activeVersion of the most recent entry
        let text = history.entries.first?.displayText ?? lastTranscript
        guard let text else { return }
        // Nothing here reads the answer: this is the menu's own re-paste, and
        // it has no face to put a failure on.
        Task { @MainActor in await TextInserter.paste(text) }
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

        // A retry must not carry a stale face into a success (#50, #209): the
        // last dictation's failure is still parked here until a new recording
        // is confirmed, and this is not one.
        if isCurrentSession(epoch) { lastError = nil }

        entry.status = .audioSaved
        entry.rawText = nil
        entry.cleanedText = nil
        entry.errorMessage = nil
        entry.cleanupMethodName = nil
        entry.translatedToLanguage = nil
        history.update(entry)

        await transcribeEntry(&entry, samples: samples, epoch: epoch)

        if entry.status == .transcribed, let text = entry.rawText {
            // Same stage the live pipeline sets (2026-08-31): a retry shows the
            // bubble too (`showsProgress` defaults true), so its cleanup call
            // gets named the same way — but only when `cleanupEntry`'s own
            // guards (no `prompt` is passed here, so it falls to
            // `settings.cleanupByDefault`, and there must be words to send)
            // mean the call actually happens; naming a call that is about to
            // no-op would be a stage nobody's bubble ever runs.
            let willCleanup = !(settings?.openaiApiKey.isEmpty ?? true)
                && (settings?.cleanupByDefault ?? false)
                && RichInput.hasSpokenWords(in: text, items: entry.items ?? [])
            if willCleanup, isCurrentSession(epoch) { llmStage = .cleanup }
            await cleanupEntry(&entry, rawText: text, endpoint: .cleanup, epoch: epoch)
            if isCurrentSession(epoch) { llmStage = nil }
        }

        history.update(entry)

        // Indicator state belongs to the newest session (#104).
        guard isCurrentSession(epoch) else { return }
        // The same face the dictation path shows (#209, F2): a retry that came
        // back with nothing says so, instead of closing as though it worked.
        if lastError == nil, entry.status != .transcribed, entry.status != .cleaned {
            lastError = .nothingCameThrough
        }
        guard lastError == nil else {
            // A model download that failed put its own face up (#209, F4) and
            // needs its reading time.
            state = .done
            scheduleAutoHide()
            return
        }
        // A history retry has no confirmation face of its own: the row it
        // rewrote is the answer, and it is already on screen (#209, V-A).
        state = .idle
    }

    // MARK: - Transcription

    /// Eagerly load both instances dictation needs so the first dictation pays
    /// no model-load latency. Non-blocking: fire from a detached Task at launch;
    /// launch never waits on it. Idempotent — joins any in-flight load.
    ///
    /// The shared cache first, always: it is where the model files are
    /// downloaded, and the private build must find them on disk rather than
    /// start a second fetch into the same directory.
    func prewarm() async {
        _ = try? await backendCache?.prepare()
        _ = try? await ownCache.prepare()
    }

    /// F4's one action (#209): the download the next dictation would attempt
    /// anyway, run now, for whoever has just fixed their connection. The
    /// automatic retry stays what it always was — this only saves the wait.
    ///
    /// The face goes back up if the connection is still down, and the shape
    /// leaves on success: there is no "downloaded" face, for the same reason
    /// there is no "pasted" one.
    func retryModelDownload() async {
        guard lastError == .modelDownloadFailed else { return }
        autoHideTask?.cancel()
        autoHideTask = nil
        lastError = nil
        state = .loadingModel
        do {
            _ = try await backendCache?.prepare()
            _ = try await ownCache.prepare()
            state = .idle
        } catch {
            log.error("model download retry failed: \(error.localizedDescription, privacy: .private)")
            surfaceFace(.modelDownloadFailed, hide: .grace)
        }
    }

    /// - Parameter showsProgress: whether this transcription may speak for the
    ///   bubble — the model-download face, the `Transcribing` face, and the
    ///   failure that replaces them. False for a `Stop recording` (#219), which
    ///   took the shape off the screen when the entry was saved: nothing
    ///   downstream may raise it again.
    private func transcribeEntry(
        _ entry: inout DictationHistoryEntry, samples: [Float], epoch: Int,
        showsProgress: Bool = true
    ) async {
        // Only a slip carrying items gets this far under the speech minimum
        // (#229), and there is nothing in a fraction of a second to ask a model
        // about. Nobody asks: FluidAudio is never handed a buffer shorter than
        // it was measured against, and a dictation that needs no transcription
        // cannot fail on a model download. It settles on its items alone.
        guard samples.count > Self.minimumSpeechSamples else {
            settle(&entry, spoken: "", words: [])
            return
        }

        // Ensure the shared cache has downloaded model files (fast no-op if already cached)
        if let cache = backendCache {
            do {
                try await cache.prepare { [weak self] _ in
                    guard showsProgress, let self, self.isCurrentSession(epoch) else { return }
                    self.state = .loadingModel
                }
            } catch is CancellationError {
                // Deliberate discard (#104): quiet stop, entry stays
                // retryable (.audioSaved) — same as the chunk loop, not a
                // scary "Model loading failed: cancelled".
                return
            } catch {
                // One plain sentence for both this and the private instance
                // below (#209, F4) — the two raw NSError descriptions were the
                // same event to whoever read them. The description itself goes
                // to the log, where detail belongs.
                log.error("model download failed: \(error.localizedDescription, privacy: .private)")
                entry.status = .failed
                entry.errorMessage = DictationFace.modelDownloadFailed.sentence
                if showsProgress, isCurrentSession(epoch) { lastError = .modelDownloadFailed }
                history.update(entry)
                return
            }
        } else {
            log.error("backendCache nil — dictation setup may not have run")
        }

        // Dictation's own instance (see `ownCache`), already warm if the launch
        // prewarm finished — and joined, not rebuilt, if it is still running.
        let backend: any TranscriptionBackend
        do {
            backend = try await ownCache.prepare()
        } catch is CancellationError {
            // Deliberate discard (#104): quiet stop, entry stays retryable.
            return
        } catch {
            log.error("backend prepare failed: \(error.localizedDescription, privacy: .private)")
            entry.status = .failed
            entry.errorMessage = DictationFace.modelDownloadFailed.sentence
            if showsProgress, isCurrentSession(epoch) { lastError = .modelDownloadFailed }
            history.update(entry)
            return
        }

        if showsProgress, isCurrentSession(epoch) { state = .processing }

        // Build chunks, merging short tails into the previous chunk. Each keeps
        // the sample it starts at: a chunk's timings are its own, so placing an
        // item past the 30 s boundary needs the offset added back (#192).
        var chunks: [(samples: [Float], startSample: Int)] = []
        for start in stride(from: 0, to: samples.count, by: Self.maxChunkSamples) {
            let end = min(start + Self.maxChunkSamples, samples.count)
            let chunk = Array(samples[start..<end])
            if chunk.count < Self.minimumSpeechSamples && !chunks.isEmpty {
                chunks[chunks.count - 1].samples.append(contentsOf: chunk)
            } else {
                chunks.append((samples: chunk, startSample: start))
            }
        }

        let transcribeStart = Date()
        var segments: [String] = []
        /// Every word of the transcript with its end time and whether a
        /// clause ended with it, in dictation-audio seconds — what an item's
        /// own second is measured against.
        var words: [RichInput.Word] = []
        var failedChunks = 0

        // Only a *thrown* attempt is retried — an empty success is silence into
        // the mic, not a failure (#103). `failedChunks` = chunks lost after retries.
        // A CancellationError is a deliberate discard (#104), not a lost chunk:
        // stop quietly, leaving the entry as it was (.audioSaved — retryable).
        // The discard already recorded itself in the diagnostic stream.
        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { return }
            do {
                let result = try await Self.withRetries(attempts: Self.retryAttempts) {
                    do {
                        return try await backend.transcribeDetailed(
                            chunk.samples, previousContext: nil
                        )
                    } catch {
                        log.error("""
                            chunk \(i + 1, privacy: .public)/\(chunks.count, privacy: .public) attempt failed: \
                            \(error.localizedDescription, privacy: .private)
                            """)
                        throw error
                    }
                }
                if !result.text.isEmpty {
                    segments.append(result.text)
                    // Words and their times are appended together, so a chunk
                    // lost after retries drops both and the rest stay aligned.
                    words += RichInput.words(
                        tokens: result.tokens,
                        audioOffset: Double(chunk.startSample) / Self.sampleRate
                    )
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
        settle(&entry, spoken: text, words: words)
    }

    /// The entry's verdict: the spoken words with every kept item at the end of
    /// the clause it happened in (#192), and what that composition says about
    /// whether anything came through.
    ///
    /// `compose` returns the spoken words when none of its items place, so the
    /// composed text is empty in exactly one case — nothing said and nothing
    /// riding along (#229). Asking compose keeps the condition from re-deriving
    /// compose's own filter.
    private func settle(
        _ entry: inout DictationHistoryEntry, spoken: String, words: [RichInput.Word]
    ) {
        let composed = RichInput.compose(spoken: spoken, items: entry.items ?? [], words: words)
        if composed.isEmpty {
            entry.status = .failed
            // One sentence for the bubble and the row alike (#209, F2).
            entry.errorMessage = DictationFace.nothingCameThrough.sentence
        } else {
            entry.status = .transcribed
            entry.rawText = composed
            log.debug("raw transcription: \(spoken, privacy: .private)")
        }
    }

    /// Single source of truth mapping an UpgradeAction to its prompt, meta
    /// labels, and failure wording, shared by the paste-time defaults and the
    /// Fn+V/Fn+T chords. Meta is written only on success (DIC-37/48).
    private func runCleanupAction(
        _ action: UpgradeAction,
        on entry: inout DictationHistoryEntry,
        rawText: String,
        epoch: Int? = nil
    ) async -> Bool {
        let basePrompt = settings?.activeCleanupPrompt ?? CleanupMode.cleanPrompt
        let prompt: String
        let modeName: String
        let translatedTo: String?
        let failureMessage: DictationFace
        let endpoint: DiagEvent.Endpoint
        switch action {
        case .cleanup:
            prompt = basePrompt
            modeName = "Cleanup"
            translatedTo = nil
            failureMessage = .cleanupFailed
            endpoint = .cleanup
        case .translate:
            prompt = basePrompt + CleanupMode.translateSuffix()
            modeName = "Translate"
            translatedTo = TranslationLanguage.english.key
            failureMessage = .translateFailed
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
    /// call itself fails — the floating indicator renders it as the F6 face
    /// instead of a fake success (#50). Paths with their own failure UI (row
    /// transforms) pass nil. Internal (not private) so tests can drive the
    /// failure path directly with a stubbed client.
    @discardableResult
    func cleanupEntry(
        _ entry: inout DictationHistoryEntry,
        rawText: String,
        prompt: String? = nil,
        failureMessage: DictationFace? = nil,
        endpoint: DiagEvent.Endpoint,
        epoch: Int? = nil
    ) async -> Bool {
        guard let settings, !settings.openaiApiKey.isEmpty else { return false }
        // Nothing of the user's own to work on — an item-only dictation (#229).
        // Every caller crosses this, so no path can stamp `.cleaned` on a text
        // the model never saw.
        guard RichInput.hasSpokenWords(in: rawText, items: entry.items ?? []) else { return false }

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
            // Only the spoken words go to the model (#192, D5): the text is cut
            // at the items it carries, the spoken parts go out in parallel, and
            // what was inserted comes back byte for byte. A dictation with no
            // items splits into one segment and this is one call, as before.
            let split = RichInput.split(rawText, items: entry.items ?? [])
            let cleaned: String
            if split.isWhole {
                cleaned = try await cleanupCall(
                    rawText, prompt: effectivePrompt, apiKey: apiKey, endpoint: endpoint
                )
            } else {
                cleaned = try await cleanupSegments(
                    split, prompt: effectivePrompt, apiKey: apiKey, endpoint: endpoint
                )
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

    /// One cleanup call, with the retries and the `apiCall` event that wrap it —
    /// one event per attempt, so retries show in the stream as failed→ok
    /// sequences (#103).
    private func cleanupCall(
        _ text: String, prompt: String, apiKey: String, endpoint: DiagEvent.Endpoint
    ) async throws -> String {
        try await Self.withRetries(
            attempts: Self.retryAttempts,
            backoff: [.milliseconds(500), .seconds(1)],
            isTransient: Self.isTransientCleanupError
        ) {
            let startedAt = Date()
            do {
                let cleaned = try await cleanupClient.cleanup(
                    rawText: text, prompt: prompt, apiKey: apiKey
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
    }

    /// The spoken parts of a dictation that carries items, cleaned in parallel
    /// and put back around the items untouched (#192). A segment that is only
    /// whitespace is not sent — there is nothing in it to clean. Any segment
    /// failing after its retries fails the whole cleanup, exactly as the single
    /// call does: the raw text is what gets pasted, items and all.
    private func cleanupSegments(
        _ split: RichInput.Split, prompt: String, apiKey: String, endpoint: DiagEvent.Endpoint
    ) async throws -> String {
        let spoken = split.segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cleaned = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, segment) in spoken.enumerated() where !segment.isEmpty {
                group.addTask {
                    (index, try await self.cleanupCall(
                        segment, prompt: prompt, apiKey: apiKey, endpoint: endpoint
                    ))
                }
            }
            var result = spoken
            for try await (index, text) in group { result[index] = text }
            return result
        }
        return split.reassembled(with: cleaned)
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
