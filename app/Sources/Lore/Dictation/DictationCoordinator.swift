import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import os

enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case loadingModel
    case processing
    case done
}

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

    /// Shared backend cache — set by AppDelegate during dictation setup.
    var backendCache: SharedBackendCache?

    /// Private backend instance for dictation transcription.
    /// Separate from the shared cache to avoid concurrent decoder state mutation
    /// when TranscriptionEngine also transcribes via the shared backend.
    private var ownBackend: (any TranscriptionBackend)?

    /// The current history entry being processed (needed for upgrades).
    private var currentEntryID: UUID?

    let history: DictationHistory
    var settings: AppSettings?

    /// `history` is injectable so tests can back it with an ephemeral
    /// UserDefaults suite instead of the user's real dictation history;
    /// `cleanupClient` so tests can force LLM failures without the network.
    init(
        history: DictationHistory = DictationHistory(),
        cleanupClient: any CleanupProviding = CleanupClient()
    ) {
        self.history = history
        self.cleanupClient = cleanupClient
    }

    /// Start capturing audio silently before hold is confirmed (pre-buffer phase).
    /// State stays .idle — indicator does not show yet.
    func startPreBuffer() {
        guard !isPreBuffering else { return }
        guard state == .idle || state == .done else { return }
        guard let settings else {
            diagLog("[DICTATION] WARNING: settings not wired — dictation disabled")
            return
        }

        autoHideTask?.cancel()
        autoHideTask = nil
        upgradeDismissTask?.cancel()
        upgradeDismissTask = nil
        isUpgradePanelVisible = false
        upgradeCountdown = nil
        currentEntryID = nil
        pendingCleanupMode = nil

        lastError = nil
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
            startMicCapture()
            // "Sound on start" (DSET-16, default off): chime at the point
            // capture actually begins (mic live), not on key-down — the
            // denied/undetermined branches never chime.
            if settings.soundOnDictationStart, let sound = NSSound(named: "Pop") {
                sound.volume = 0.4
                sound.play()
            }
            diagLog("[DICTATION] pre-buffering started")
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
        state = .recording
        diagLog("[DICTATION] recording confirmed (pre-buffer kept)")
    }

    /// Cancel pre-buffer (user tapped instead of holding).
    func cancelPreBuffer() {
        guard isPreBuffering else { return }
        isPreBuffering = false
        stopMicCapture()
        accumulatedSamples.removeAll()
        diagLog("[DICTATION] pre-buffer discarded (tap)")
    }

    func stopRecording() async {
        guard state == .recording else { return }

        // Audio tail: keep recording 300ms to capture trailing speech
        try? await Task.sleep(for: .milliseconds(300))

        // Re-check state — may have been discarded during the tail
        guard state == .recording else { return }

        stopMicCapture()

        let samples = accumulatedSamples
        accumulatedSamples.removeAll()

        let durationSeconds = Double(samples.count) / 16000.0
        diagLog("[DICTATION] recording stopped, samples=\(samples.count), duration=\(String(format: "%.1f", durationSeconds))s")

        // Zero frames captured = mic failure (e.g. the macOS 27 HAL stall), not a
        // brief utterance. Surface it instead of silently going idle, and don't save
        // an empty history entry. A non-empty but short recording falls through to
        // the quiet "too short" path below, preserving prior behavior.
        guard !samples.isEmpty else {
            // Prefer a concrete bus capture error if one was recorded; otherwise the
            // unified message. Fn is already released here (stop came from the release
            // path), so use the grace hide directly.
            let message = if let lastError { lastError } else { await micUnavailableMessage() }
            diagLog("[DICTATION] zero frames captured — mic failure: \(message)")
            surfaceMicError(message, hide: .grace)
            return
        }

        // Audio was captured, so the recording is proceeding to save/transcribe. If a
        // transient stall set lastError (watchdog or the immediate captureError check)
        // and the mic then recovered and delivered frames, clear it now so the success
        // path doesn't render a stale red error row at `.done`.
        lastError = nil

        guard samples.count > Self.minimumSpeechSamples else {
            log.info("Too short, ignoring")
            state = .idle
            return
        }

        // STEP 1: Save audio to disk FIRST — never lose the recording.
        // Sync the audio retention limit from Settings so add-time pruning
        // honors the user's choice (#52); history stays settings-agnostic.
        history.audioRetentionLimit = settings?.dictationAudioRetentionCount ?? 500
        let audioFilename = history.saveAudio(samples)
        var entry = DictationHistoryEntry(durationSeconds: durationSeconds, audioFilename: audioFilename)
        history.add(entry)
        currentEntryID = entry.id
        diagLog("[DICTATION] audio saved: \(audioFilename ?? "FAILED")")

        // STEP 2: Transcribe
        await transcribeEntry(&entry, samples: samples)

        guard entry.status == .transcribed, let rawText = entry.rawText else {
            // Transcription failed — update history, go to done briefly
            history.update(entry)
            state = .done
            scheduleAutoHide()
            return
        }

        // STEP 3: Determine cleanup action (pre-paste mode > defaults) and run
        let pending = pendingCleanupMode
        pendingCleanupMode = nil
        let cleanupEnabled = settings?.cleanupByDefault ?? false
        let translateEnabled = settings?.translationByDefault ?? false
        let hasApiKey = !(settings?.openaiApiKey.isEmpty ?? true)
        let didCleanup: Bool

        // Mode name and translation meta are written only when the cleanup
        // actually succeeded — a swallowed API failure must not relabel the
        // pasted raw text (DIC-37/48). Pre-paste mode (Fn+V/Fn+T) overrides
        // defaults; translate-by-default implies cleanup.
        if let pending, hasApiKey {
            didCleanup = await runCleanupAction(pending, on: &entry, rawText: rawText)
        } else if translateEnabled && hasApiKey {
            didCleanup = await runCleanupAction(.translate, on: &entry, rawText: rawText)
        } else if cleanupEnabled && hasApiKey {
            didCleanup = await runCleanupAction(.cleanup, on: &entry, rawText: rawText)
        } else {
            didCleanup = false
        }

        // Paste immediately (always paste the best version)
        if let text = entry.cleanedText ?? entry.rawText {
            lastTranscript = text
            TextInserter.paste(text)
            diagLog("[DICTATION] pasted: \(text.prefix(80))")
        }

        history.update(entry)
        state = .done

        // STEP 4: Show upgrade options — skip if user explicitly chose a pre-paste mode.
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
            diagLog("[DICTATION] upgrade failed: no entry or raw text")
            scheduleAutoHide()
            return
        }

        state = .processing
        // A retry must not carry a stale failure row into a success (#50).
        lastError = nil
        diagLog("[DICTATION] applying upgrade: \(action)")

        // Meta is written only on success: a failed upgrade keeps the
        // previous cleaned text and whatever meta truthfully described it
        // (DIC-37/48). `kept: true` selects the upgrade failure wording.
        _ = await runCleanupAction(action, on: &entry, rawText: rawText, kept: true)

        // Undo previous paste, then paste upgraded text
        if let text = entry.cleanedText ?? entry.rawText {
            lastTranscript = text
            TextInserter.undoAndPaste(text)
            diagLog("[DICTATION] upgrade pasted (undo+paste): \(text.prefix(80))")
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
        diagLog("[DICTATION] discarded from state: \(state)")
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
            diagLog("[DICTATION] WARNING: audioBus not wired")
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
            diagLog("[DICTATION] mic capture error: \(micError)")
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
                diagLog("[DICTATION] no mic audio after 5s")
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
        diagLog("[DICTATION] pending mode: \(pendingCleanupMode.map { "\($0)" } ?? "none")")
    }

    func pasteLastTranscript() {
        // Respect activeVersion of the most recent entry
        if let entry = history.entries.first, let text = entry.displayText {
            TextInserter.paste(text)
        } else if let text = lastTranscript {
            TextInserter.paste(text)
        }
    }

    /// Retry transcription for a failed or audio-only entry
    func retryTranscription(entryID: UUID) async {
        guard var entry = history.entries.first(where: { $0.id == entryID }),
              let filename = entry.audioFilename,
              let samples = history.loadAudio(filename: filename) else {
            diagLog("[DICTATION] retry failed: no audio for entry")
            return
        }

        entry.status = .audioSaved
        entry.rawText = nil
        entry.cleanedText = nil
        entry.errorMessage = nil
        entry.cleanupMethodName = nil
        entry.translatedToLanguage = nil
        history.update(entry)

        await transcribeEntry(&entry, samples: samples)

        if entry.status == .transcribed, let text = entry.rawText {
            await cleanupEntry(&entry, rawText: text)
        }

        history.update(entry)

        if entry.status == .transcribed || entry.status == .cleaned {
            state = .done
            scheduleAutoHide()
        } else {
            state = .idle
        }
    }

    // MARK: - Transcription

    private func transcribeEntry(_ entry: inout DictationHistoryEntry, samples: [Float]) async {
        // Ensure the shared cache has downloaded model files (fast no-op if already cached)
        if let cache = backendCache {
            do {
                try await cache.prepare { [weak self] status in
                    Task { @MainActor in self?.state = .loadingModel }
                }
            } catch {
                entry.status = .failed
                entry.errorMessage = "Model loading failed: \(error.localizedDescription)"
                lastError = entry.errorMessage
                history.update(entry)
                return
            }
        } else {
            diagLog("[DICTATION] backendCache nil — dictation setup may not have run")
        }

        // Use a private backend instance to avoid sharing mutable decoder state
        // with TranscriptionEngine's backend from the shared cache.
        // Creating a fresh backend when model files are already on disk is fast (~1s).
        if ownBackend == nil {
            diagLog("[DICTATION] creating private backend")
            let fresh = ParakeetBackend()
            do {
                try await fresh.prepare(onStatus: { _ in }, onProgress: { _ in })
            } catch {
                entry.status = .failed
                entry.errorMessage = "Backend prepare failed: \(error.localizedDescription)"
                lastError = entry.errorMessage
                history.update(entry)
                return
            }
            ownBackend = fresh
        }

        guard let backend = ownBackend else {
            entry.status = .failed
            entry.errorMessage = "Backend not available after prepare"
            history.update(entry)
            return
        }

        state = .processing

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

        diagLog("[DICTATION] transcribing \(chunks.count) chunk(s), total \(samples.count) samples")
        var segments: [String] = []

        for (i, chunk) in chunks.enumerated() {
            do {
                let segment = try await backend.transcribe(chunk, previousContext: nil)
                if !segment.isEmpty {
                    segments.append(segment)
                    diagLog("[DICTATION] chunk \(i+1)/\(chunks.count): \(segment.prefix(60))")
                }
            } catch {
                diagLog("[DICTATION] chunk \(i+1)/\(chunks.count) failed: \(error), skipping")
            }
        }

        let text = segments.joined(separator: " ")
        if text.isEmpty {
            entry.status = .failed
            entry.errorMessage = "Transcription produced empty result"
        } else {
            entry.status = .transcribed
            entry.rawText = text
            diagLog("[DICTATION] raw transcription: \(text)")
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
        kept: Bool = false
    ) async -> Bool {
        let basePrompt = settings?.activeCleanupPrompt ?? CleanupMode.cleanPrompt
        let prompt: String
        let modeName: String
        let translatedTo: String?
        let failureMessage: String
        switch action {
        case .cleanup:
            prompt = basePrompt
            modeName = "Cleanup"
            translatedTo = nil
            failureMessage = kept ? Self.cleanupFailedKeptText : Self.cleanupFailedPastedRaw
        case .translate:
            prompt = basePrompt + CleanupMode.translateSuffix()
            modeName = "Translate"
            translatedTo = TranslationLanguage.english.key
            failureMessage = kept ? Self.translateFailedKeptText : Self.translateFailedPastedRaw
        }

        guard await cleanupEntry(
            &entry, rawText: rawText, prompt: prompt, failureMessage: failureMessage
        ) else { return false }

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
        failureMessage: String? = nil
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

        diagLog("[DICTATION] calling cleanup API...")
        let apiKey = settings.openaiApiKey

        do {
            let cleaned = try await cleanupClient.cleanup(rawText: rawText, prompt: effectivePrompt, apiKey: apiKey)
            entry.cleanedText = cleaned
            entry.status = .cleaned
            entry.activeVersion = .cleaned
            diagLog("[DICTATION] cleaned: \(cleaned.prefix(80))")
            return true
        } catch {
            diagLog("[DICTATION] cleanup failed: \(error), using raw text")
            if let failureMessage {
                lastError = failureMessage
            }
            return false
        }
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
            diagLog("[DICTATION] retroactive cleanup: no raw text for entry")
            return false
        }
        guard !prompt.isEmpty else { return false }

        guard await cleanupEntry(&entry, rawText: text, prompt: prompt) else { return false }
        entry.cleanupMethodName = methodKey
        entry.translatedToLanguage = languageKey
        history.update(entry)
        return true
    }

}
