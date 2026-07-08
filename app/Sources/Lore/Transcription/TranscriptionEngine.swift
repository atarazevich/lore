import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import os

private let engineLog = Logger(subsystem: "com.lore.app", category: "TranscriptionEngine")

enum TranscriptionEngineError: LocalizedError {
    case transcriberNotInitialized

    var errorDescription: String? {
        switch self {
        case .transcriberNotInitialized:
            "Transcription engine is not initialized. Please check your audio settings."
        }
    }
}

/// Orchestrates dual StreamingTranscriber instances for mic (you) and system audio (them).
@Observable
@MainActor
final class TranscriptionEngine {
    enum Mode {
        case live
        case scripted([Utterance])
    }

    // These properties are read from SwiftUI body during view evaluation.
    // SwiftUI's ViewBodyAccessor doesn't carry MainActor executor context
    // in Swift 6.2, so @MainActor-isolated @Observable properties trigger
    // a failing runtime check in SerialExecutor.isMainExecutor.getter
    // (EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE).
    //
    // We use @ObservationIgnored nonisolated(unsafe) backing storage with
    // manual observation tracking to bypass the MainActor check while
    // keeping SwiftUI reactivity. Mutations only happen on MainActor.
    @ObservationIgnored nonisolated(unsafe) private var _isRunning = false
    var isRunning: Bool {
        get { access(keyPath: \.isRunning); return _isRunning }
        set { withMutation(keyPath: \.isRunning) { _isRunning = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _assetStatus: String = "Ready"
    var assetStatus: String {
        get { access(keyPath: \.assetStatus); return _assetStatus }
        set { withMutation(keyPath: \.assetStatus) { _assetStatus = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _lastError: String?
    var lastError: String? {
        get { access(keyPath: \.lastError); return _lastError }
        set { withMutation(keyPath: \.lastError) { _lastError = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _needsModelDownload = false
    var needsModelDownload: Bool {
        get { access(keyPath: \.needsModelDownload); return _needsModelDownload }
        set { withMutation(keyPath: \.needsModelDownload) { _needsModelDownload = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _downloadConfirmed = false
    var downloadConfirmed: Bool {
        get { access(keyPath: \.downloadConfirmed); return _downloadConfirmed }
        set { withMutation(keyPath: \.downloadConfirmed) { _downloadConfirmed = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _downloadProgress: Double?
    /// Fraction complete (0…1) during model download, nil when not downloading.
    var downloadProgress: Double? {
        get { access(keyPath: \.downloadProgress); return _downloadProgress }
        set { withMutation(keyPath: \.downloadProgress) { _downloadProgress = newValue } }
    }

    private let systemCapture = SystemAudioCapture()
    private let audioBus: AudioBus
    private let transcriptStore: TranscriptStore
    private let settings: AppSettings
    private let mode: Mode

    /// Audio level from mic for the UI meter.
    /// nonisolated is safe here — audioBus.audioLevel and the `_micMuted` SyncBool
    /// are both thread-safe (NSLock).
    nonisolated var audioLevel: Float {
        switch mode {
        case .live:
            _micMuted.value ? 0 : audioBus.audioLevel
        case .scripted:
            _isRunning ? 0.35 : 0
        }
    }

    /// Engine-local mic mute (#66). Consulted only in THIS engine's mic sink: while
    /// muted, the recorder's mic track records silence (file keeps full duration) and
    /// VAD/[you] transcription sees nothing; the reported audio level reads 0. Other
    /// AudioBus consumers (dictation) and system-audio capture are unaffected — the bus
    /// itself has no mute surface. Cleared when the session ends, so mute can never
    /// outlive the meeting.
    private let _micMuted = SyncBool()
    nonisolated var isMicMuted: Bool {
        get { _micMuted.value }
        set { _micMuted.value = newValue }
    }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?
    /// Keeps the mic stream alive for the audio level meter when transcription isn't running.
    /// Tracks the AudioBus subscription for mic capture.
    private var micConsumerID: UUID?

    /// Separate backend instances for mic and system audio.
    /// Parakeet keeps mutable decoder state per manager, so mic and system audio
    /// need separate instances even when they share the same loaded model files.
    private var micBackend: (any TranscriptionBackend)?
    private var systemBackend: (any TranscriptionBackend)?
    private var vadManager: VadManager?

    /// Cached backends survive across start/stop cycles to avoid reloading models from disk.
    private var cachedMicBackend: (any TranscriptionBackend)?
    private var cachedSystemBackend: (any TranscriptionBackend)?

    /// Audio recorder for tapping streams (set by ContentView when recording is enabled).
    var audioRecorder: AudioRecorder?

    /// Shared backend cache — if set, the engine reuses the cached backend for mic
    /// transcription instead of loading a duplicate model.
    var sharedBackendCache: SharedBackendCache?

    /// Tracks the resolved mic device ID currently in use.
    private var currentMicDeviceID: AudioDeviceID = 0

    /// Tracks whether user selected "System Default" (0) or a specific device.
    private var userSelectedDeviceID: AudioDeviceID = 0

    /// Listens for default output device changes at the OS level.
    private var defaultOutputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// True from `isRunning = true` in start() until its mic/system wiring is complete.
    /// While set, restartMic() defers (records pendingMicDeviceID, no task) so a Settings
    /// device change can't race the initial subscription (#64 review; also narrows the
    /// pre-existing #30 stray-subscription window).
    private var isStarting = false
    private var micRestartTask: Task<Void, Never>?
    private var sysRestartTask: Task<Void, Never>?
    private var pendingMicDeviceID: AudioDeviceID?
    private var pendingSystemAudioRestart = false

    init(transcriptStore: TranscriptStore, settings: AppSettings, audioBus: AudioBus = AudioBus(), mode: Mode = .live) {
        self.transcriptStore = transcriptStore
        self.settings = settings
        self.audioBus = audioBus
        self.mode = mode
        switch mode {
        case .live:
            self.needsModelDownload = Self.modelNeedsDownload()
        case .scripted:
            self.needsModelDownload = false
        }
    }

    func refreshModelAvailability() {
        switch mode {
        case .live:
            needsModelDownload = Self.modelNeedsDownload()
        case .scripted:
            needsModelDownload = false
        }
    }

    func start() async {
        engineLog.debug("start() called, isRunning=\(self.isRunning, privacy: .public)")
        guard !isRunning else { return }
        lastError = nil
        refreshModelAvailability()

        if case .scripted(let scriptedUtterances) = mode {
            downloadConfirmed = false
            // "Ready" is the no-status sentinel — recording state is shown by
            // the banner/REC pill, not a status line (#57).
            assetStatus = "Ready"
            isRunning = true
            for utterance in scriptedUtterances {
                transcriptStore.append(utterance)
            }
            return
        }

        // Block start if models need downloading and user hasn't confirmed
        if needsModelDownload && !downloadConfirmed {
            return
        }

        guard await ensureMicrophonePermission() else { return }

        isRunning = true
        // Mic-restart requests are deferred while start is in flight (#64 review) —
        // restartMic() records pendingMicDeviceID and the tail of start() applies it.
        isStarting = true
        defer { isStarting = false }

        // 1. Load transcription models via backend protocol
        let canReuseCache = cachedMicBackend != nil && cachedSystemBackend != nil
        let modelLoadStart = Date()
        var usedSharedCacheBackend = false

        if canReuseCache {
            engineLog.debug("reusing cached backends")
            self.micBackend = cachedMicBackend
            self.systemBackend = cachedSystemBackend
            assetStatus = "Models ready"
        }

        if !canReuseCache {
            let isDownloading = needsModelDownload
            assetStatus = isDownloading
                ? "Downloading Parakeet TDT v3..."
                : "Loading Parakeet TDT v3..."
            if isDownloading { downloadProgress = 0 }
            engineLog.debug("loading transcription model")
        }

        // Which model the `do` block is currently loading, so a failure is attributed
        // to the model that actually failed. VAD lives inside the same `do`, and used
        // to be reported as an ASR failure.
        var loadingModel: DiagEvent.ModelKind = .asr
        var phaseStart = modelLoadStart

        do {
            if !canReuseCache {
                // Try shared cache first — reuse the preloaded dictation backend as mic backend
                if let sharedBackend = sharedBackendCache?.backend {
                    self.micBackend = sharedBackend
                    usedSharedCacheBackend = true
                    engineLog.debug("reusing shared cache backend for mic")
                } else {
                    let mic = ParakeetBackend()
                    try await mic.prepare(
                        onStatus: { [weak self] status in
                            Task { @MainActor in
                                self?.assetStatus = status
                            }
                        },
                        onProgress: { [weak self] fraction in
                            Task { @MainActor in
                                self?.downloadProgress = fraction
                            }
                        }
                    )
                    self.micBackend = mic
                }

                // Parakeet needs a separate backend for system audio (mutable decoder state).
                let sys = ParakeetBackend()
                try await sys.prepare { _ in }
                self.systemBackend = sys

                // Store in cache for next session.
                // Only cache engine-created backends — the shared cache backend
                // is owned by SharedBackendCache.
                let usedSharedBackend = (self.micBackend as AnyObject) === (sharedBackendCache?.backend as AnyObject)
                if !usedSharedBackend {
                    cachedMicBackend = self.micBackend
                }
                cachedSystemBackend = self.systemBackend
            }

            // The ASR backend is up. A cache hit did no loading, so its duration is 0
            // rather than a stopwatch reading of a few skipped `if`s.
            let fromCache = canReuseCache || usedSharedCacheBackend
            DiagStore.record(.modelLoad(
                model: .asr,
                outcome: .ok,
                seconds: fromCache ? 0 : Date().timeIntervalSince(modelLoadStart),
                fromCache: fromCache
            ))

            if self.vadManager == nil {
                assetStatus = "Loading VAD model..."
                loadingModel = .vad
                phaseStart = Date()
                let vad = try await VadManager()
                self.vadManager = vad
                DiagStore.record(.modelLoad(
                    model: .vad,
                    outcome: .ok,
                    seconds: Date().timeIntervalSince(phaseStart),
                    fromCache: false
                ))
            }

            needsModelDownload = false
            downloadConfirmed = false
            downloadProgress = nil
            assetStatus = "Models ready"
        } catch {
            let msg = "Failed to load models: \(error.localizedDescription)"
            DiagStore.record(.modelLoad(
                model: loadingModel,
                outcome: .failed,
                seconds: Date().timeIntervalSince(phaseStart),
                fromCache: loadingModel == .asr && (canReuseCache || usedSharedCacheBackend)
            ))
            // The underlying error can name model cache paths — private.
            engineLog.error("failed to load models: \(error.localizedDescription, privacy: .private)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            downloadProgress = nil
            // Clear corrupt cache so the next attempt triggers a fresh download
            invalidateBackendCache()
            ParakeetBackend().clearModelCache()
            DiagStore.record(.modelCacheCleared)
            needsModelDownload = true
            downloadConfirmed = false
            return
        }

        guard let vadManager else { return }

        // 2. Start mic capture. Device resolution is HAL enumeration — it runs on the
        // shared HAL queue, never on the main thread (#64: main blocked on HALB_Mutex
        // here was one leg of the stop→start deadlock triangle).
        userSelectedDeviceID = settings.inputDeviceID
        guard let targetMicID = await resolvedMicDeviceID(for: settings.inputDeviceID) else {
            let msg = Self.unavailableMicMessage
            engineLog.error("no usable mic device")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            return
        }
        // stop() may have run while resolution was in flight — don't subscribe a mic
        // stream for a session that is already torn down (#64 review).
        guard isRunning else {
            engineLog.debug("stopped during device resolution — aborting start")
            return
        }
        currentMicDeviceID = targetMicID
        engineLog.debug("starting mic capture, targetMicID=\(targetMicID, privacy: .public)")
        startMicStream(
            vadManager: vadManager,
            deviceID: targetMicID
        )

        // Check for immediate mic capture failure. AudioBus already recorded the
        // typed captureFailed event; this only surfaces the message to the UI.
        if let micError = audioBus.captureError {
            engineLog.error("mic capture error: \(micError, privacy: .private)")
            lastError = micError
        }

        // Health check: if mic produces no audio within 5 seconds, surface error.
        // AudioBus handles engine-level health monitoring and auto-restart internally.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.isRunning else { return }
            if !self.audioBus.hasCapturedFrames && self.audioBus.captureError == nil {
                engineLog.error("no mic audio after 5s")
                self.lastError = MicrophonePermission.noAudioMessage
            }
        }

        // 3. Start system audio capture
        await startSystemAudioStream(vadManager: vadManager)

        // Back to the no-status sentinel: a persistent "Transcribing (model)"
        // line was one of four simultaneous recording indicators (#57) — the
        // red banner is the one live indicator.
        assetStatus = "Ready"

        // Install CoreAudio listener for output device changes (system audio restart)
        installDefaultOutputDeviceListener()

        // Apply a device change that arrived while start was in flight (#64 review:
        // restartMic no-ops during isStarting instead of racing the mic subscription).
        isStarting = false
        if pendingMicDeviceID != nil {
            startMicRestartLoopIfNeeded()
        }
    }

    /// Restart only the mic capture with a new device, keeping system audio and models intact.
    /// Pass the raw setting value (0 = system default, or a specific AudioDeviceID).
    func restartMic(inputDeviceID: AudioDeviceID) {
        if case .scripted = mode { return }
        guard isRunning else { return }
        pendingMicDeviceID = inputDeviceID

        // start() is still wiring the first mic stream — defer; the tail of start()
        // drains pendingMicDeviceID once the initial subscription exists (#64 review).
        guard !isStarting else {
            engineLog.debug("mic swap deferred until start completes (device \(inputDeviceID, privacy: .public))")
            return
        }
        startMicRestartLoopIfNeeded()
    }

    private func startMicRestartLoopIfNeeded() {
        if micRestartTask != nil {
            engineLog.debug("mic swap queued restart")
            return
        }

        micRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.micRestartTask = nil }

            while self.isRunning, let requestedDeviceID = self.pendingMicDeviceID {
                self.pendingMicDeviceID = nil
                await self.performMicRestart(inputDeviceID: requestedDeviceID)
            }
        }
    }

    // MARK: - Default Output Device Listener (input device is pinned at capture start, #39)

    private func installDefaultOutputDeviceListener() {
        guard defaultOutputDeviceListenerBlock == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning else { return }
                self.restartSystemAudio()
            }
        }
        defaultOutputDeviceListenerBlock = block

        // Listener registration is a HAL call — serialize it on the shared HAL queue,
        // never on the main thread (#64). Install/remove stay ordered (serial queue).
        // nonisolated(unsafe): the block only crosses into the registration call; it is
        // delivered on DispatchQueue.main and removed later by identity (same object).
        nonisolated(unsafe) let listenerBlock = block
        AudioBus.performHALOperation {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listenerBlock
            )
        }
    }

    private func removeDefaultOutputDeviceListener() {
        guard let block = defaultOutputDeviceListenerBlock else { return }
        defaultOutputDeviceListenerBlock = nil

        nonisolated(unsafe) let listenerBlock = block
        AudioBus.performHALOperation {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listenerBlock
            )
        }
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch MicrophonePermission.status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await MicrophonePermission.request()
            if !granted {
                lastError = MicrophonePermission.requestDeniedMessage
                assetStatus = "Ready"
            }
            return granted
        case .denied, .restricted:
            lastError = MicrophonePermission.deniedMessage
            assetStatus = "Ready"
            return false
        @unknown default:
            lastError = MicrophonePermission.unknownMessage
            assetStatus = "Ready"
            return false
        }
    }

    func finalize() async {
        clearMicMuteForSessionEnd()
        if case .scripted = mode {
            isRunning = false
            assetStatus = "Ready"
            transcriptStore.volatileYouText = ""
            transcriptStore.volatileThemText = ""
            return
        }

        removeDefaultOutputDeviceListener()
        micRestartTask?.cancel()
        sysRestartTask?.cancel()
        micRestartTask = nil
        sysRestartTask = nil
        pendingMicDeviceID = nil
        pendingSystemAudioRestart = false

        // Unsubscribe from audio bus. Capture keeps running only if another consumer
        // (e.g. dictation) remains; otherwise the bus tears down and frees the mic (#30).
        if let id = micConsumerID {
            audioBus.unsubscribe(id)
            micConsumerID = nil
        }
        systemCapture.finishStream()

        await micTask?.value
        await sysTask?.value

        await systemCapture.stop()

        micTask = nil
        sysTask = nil
        pendingMicDeviceID = nil
        currentMicDeviceID = 0

        // NOTE: cachedMicBackend/cachedSystemBackend are intentionally preserved
        // across sessions to avoid model reload. Call invalidateBackendCache() to release.
        micBackend = nil
        systemBackend = nil
        isRunning = false
        assetStatus = "Ready"
    }

    func stop() {
        clearMicMuteForSessionEnd()
        if case .scripted = mode {
            isRunning = false
            assetStatus = "Ready"
            transcriptStore.volatileYouText = ""
            transcriptStore.volatileThemText = ""
            return
        }

        removeDefaultOutputDeviceListener()
        micRestartTask?.cancel()
        sysRestartTask?.cancel()
        micRestartTask = nil
        sysRestartTask = nil
        pendingMicDeviceID = nil
        pendingSystemAudioRestart = false
        micTask?.cancel()
        sysTask?.cancel()
        micTask = nil
        sysTask = nil
        if let id = micConsumerID {
            audioBus.unsubscribe(id)
            micConsumerID = nil
        }
        Task { await systemCapture.stop() }
        currentMicDeviceID = 0
        micBackend = nil
        systemBackend = nil
        isRunning = false
        assetStatus = "Ready"
    }

    private func performMicRestart(inputDeviceID: AudioDeviceID, force: Bool = false) async {
        guard isRunning, let vadManager else { return }

        userSelectedDeviceID = inputDeviceID

        guard let targetMicID = await resolvedMicDeviceID(for: inputDeviceID) else {
            let msg = Self.unavailableMicMessage
            engineLog.error("mic swap failed: no usable mic device")
            lastError = msg
            return
        }
        // stop()/finalize() may have run during the resolution hop (#64 review).
        guard isRunning else { return }

        if !force, targetMicID == currentMicDeviceID {
            engineLog.debug("mic swap: same device \(targetMicID, privacy: .public), skipping")
            return
        }

        engineLog.debug("mic swap: \(self.currentMicDeviceID, privacy: .public) -> \(targetMicID, privacy: .public)")

        // Unsubscribe old stream, switch device on AudioBus, re-subscribe
        if let id = micConsumerID {
            audioBus.unsubscribe(id)
            micConsumerID = nil
        }
        await micTask?.value

        if Task.isCancelled || !isRunning {
            return
        }

        micTask = nil
        audioBus.switchDevice(targetMicID)
        startMicStream(
            vadManager: vadManager,
            deviceID: targetMicID
        )
        currentMicDeviceID = targetMicID
        lastError = nil

        engineLog.debug("mic restarted on device \(targetMicID, privacy: .public)")
    }

    private func restartSystemAudio() {
        guard isRunning else { return }
        pendingSystemAudioRestart = true

        if sysRestartTask != nil {
            engineLog.debug("system audio swap queued")
            return
        }

        sysRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.sysRestartTask = nil }

            while self.isRunning, self.pendingSystemAudioRestart {
                self.pendingSystemAudioRestart = false
                await self.performSystemAudioRestart()
            }
        }
    }

    private func performSystemAudioRestart() async {
        guard isRunning, let vadManager else { return }

        engineLog.debug("restarting system audio stream")

        systemCapture.finishStream()
        await sysTask?.value

        if Task.isCancelled || !isRunning {
            return
        }

        sysTask = nil
        await systemCapture.stop()
        await startSystemAudioStream(vadManager: vadManager)

        engineLog.debug("system audio stream restarted")
    }

    private func startMicStream(
        vadManager: VadManager,
        deviceID: AudioDeviceID
    ) {
        let (id, rawStream) = audioBus.subscribe(deviceID: deviceID)
        micConsumerID = id
        // Mute gate sits closest to the bus so everything downstream — the recorder tap
        // and the VAD/transcriber — sees silence while muted (#66).
        var micStream = Self.mutedStream(rawStream, muted: _micMuted)
        if let recorder = audioRecorder {
            micStream = Self.tappedStream(micStream) { buffer in
                recorder.writeMicBuffer(buffer)
            }
        }
        let store = transcriptStore
        guard let micTranscriber = makeTranscriber(
            speaker: .you,
            vadManager: vadManager,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text in
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you))
                }
            }
        ) else {
            lastError = "Failed to create transcriber. Try restarting."
            isRunning = false
            assetStatus = "Ready"
            return
        }
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }
    }

    private func startSystemAudioStream(
        vadManager: VadManager
    ) async {
        engineLog.debug("starting system audio capture")

        let sysStreams: SystemAudioCapture.CaptureStreams
        do {
            sysStreams = try await systemCapture.bufferStream()
            DiagStore.record(.systemAudioCapture(outcome: .ok, osStatus: nil))
            clearSystemAudioErrorIfPresent()
        } catch {
            let msg = "Failed to start system audio: \(error.localizedDescription)"
            DiagStore.record(.systemAudioCapture(
                outcome: .failed,
                osStatus: (error as? SystemAudioCapture.CaptureError)?.osStatus
            ))
            engineLog.error("failed to start system audio: \(error.localizedDescription, privacy: .private)")
            lastError = msg
            return
        }

        var sysStream = sysStreams.systemAudio
        if let recorder = audioRecorder {
            sysStream = Self.tappedStream(sysStream) { buffer in
                recorder.writeSysBuffer(buffer)
            }
        }

        let store = transcriptStore
        guard let sysTranscriber = makeTranscriber(
            speaker: .them,
            vadManager: vadManager,
            onPartial: { text in
                Task { @MainActor in store.volatileThemText = text }
            },
            onFinal: { text in
                Task { @MainActor in
                    store.volatileThemText = ""
                    store.append(Utterance(text: text, speaker: .them))
                }
            }
        ) else {
            lastError = "Failed to create the system-audio transcriber. Try restarting."
            return
        }

        sysTask = Task.detached {
            await sysTranscriber.run(stream: sysStream)
        }
    }

    private func makeTranscriber(
        speaker: Speaker,
        vadManager: VadManager,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void
    ) -> StreamingTranscriber? {
        let backend = speaker == .you ? micBackend : systemBackend
        guard let backend else {
            engineLog.error("makeTranscriber called without initialized backend for \(speaker.storageKey, privacy: .public)")
            return nil
        }
        return StreamingTranscriber(
            backend: backend,
            vadManager: vadManager,
            speaker: speaker,
            onPartial: onPartial,
            onFinal: onFinal
        )
    }

    private func resolvedMicDeviceID(for inputDeviceID: AudioDeviceID) async -> AudioDeviceID? {
        // One allowlist selection per (re)start, fresh enumeration each call (#39).
        // Wireless inputs redirect to built-in; stale device IDs fall back to default.
        // Runs on the shared HAL queue — never on the main thread (#64).
        await AudioBus.resolveBestInputDevice(requested: inputDeviceID)?.deviceID
    }

    /// Selection only fails when no input devices exist at all — stale selected
    /// device IDs silently fall back to the default/built-in mic (#39).
    private static let unavailableMicMessage = "No microphone is currently available."

    private static func modelNeedsDownload() -> Bool {
        if case .needsDownload = ParakeetBackend().checkStatus() {
            return true
        }
        return false
    }

    /// Wrap the mic stream with an engine-local mute gate (#66): while `muted` is set,
    /// each buffer is replaced by a silent buffer of the same format and length, so
    /// downstream consumers (recorder tap, VAD/transcriber) see full-duration silence
    /// rather than a gap. Buffers are never zeroed in place — the bus yields the same
    /// buffer instance to every consumer, and other consumers must keep their audio.
    nonisolated static func mutedStream(
        _ stream: AsyncStream<AVAudioPCMBuffer>,
        muted: SyncBool
    ) -> AsyncStream<AVAudioPCMBuffer> {
        // Allocation failure of a silent buffer is practically impossible for these
        // small buffers; if it ever happens, the nil transform drops the frame rather
        // than passing audio through while the user believes they're muted.
        mappedStream(stream) { muted.value ? Self.silentBuffer(like: $0) : $0 }
    }

    /// A zeroed buffer matching the given buffer's format and frame length.
    private nonisolated static func silentBuffer(like buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let silent = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        silent.frameLength = buffer.frameLength
        for audioBuffer in UnsafeMutableAudioBufferListPointer(silent.mutableAudioBufferList) {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
        return silent
    }

    /// Wrap an audio stream to forward each buffer to a synchronous tap before yielding it downstream.
    private nonisolated static func tappedStream(
        _ stream: AsyncStream<AVAudioPCMBuffer>,
        tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> AsyncStream<AVAudioPCMBuffer> {
        mappedStream(stream) { tap($0); return $0 }
    }

    /// Shared skeleton for the per-buffer stream wrappers above: yields
    /// `transform(buffer)` downstream; nil from the transform drops the frame.
    private nonisolated static func mappedStream(
        _ stream: AsyncStream<AVAudioPCMBuffer>,
        transform: @escaping @Sendable (AVAudioPCMBuffer) -> AVAudioPCMBuffer?
    ) -> AsyncStream<AVAudioPCMBuffer> {
        struct Box: @unchecked Sendable { let stream: AsyncStream<AVAudioPCMBuffer> }
        let box = Box(stream: stream)
        let (output, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        Task {
            for await buffer in box.stream {
                guard let transformed = transform(buffer) else { continue }
                nonisolated(unsafe) let t = transformed
                continuation.yield(t)
            }
            continuation.finish()
        }
        return output
    }

    private func clearSystemAudioErrorIfPresent() {
        guard let lastError else { return }
        if lastError.localizedCaseInsensitiveContains("system audio") ||
            lastError.localizedCaseInsensitiveContains("audio output device") {
            self.lastError = nil
        }
    }

    /// Mute must not outlive the session (#66): the banner button is the only unmute
    /// control and it disappears when the meeting ends — the next session starts live.
    private func clearMicMuteForSessionEnd() {
        guard _micMuted.value else { return }
        _micMuted.value = false
        engineLog.debug("mic mute -> off (session ended)")
    }

    /// Discard cached backends so the next start() creates fresh ones.
    private func invalidateBackendCache() {
        cachedMicBackend = nil
        cachedSystemBackend = nil
        engineLog.debug("backend cache invalidated")
    }
}
